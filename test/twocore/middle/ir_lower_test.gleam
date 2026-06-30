//// Unit 11a tests — the IR→IR Safe POLICY pass, asserted against the policy/spec, not the
//// emitter's output (D8). Two layers:
////   - IR-level: hand-written `ir.Module` fixtures prove the capability gate (fail-closed)
////     and the `Charge` insertion structurally;
////   - end-to-end: a fixture is lowered → emitted → built → loaded → run, proving metering
////     ACCUMULATES while results are UNCHANGED and the constant-space loop stays bounded
////     with metering on (overview §11a verification).

import gleam/list
import gleam/option
import gleam/set
import twocore/ir
import twocore/middle/ir_lower
import twocore/pipeline
import twocore/runtime/instance
import twocore/runtime/profiles
import twocore/runtime/rt_bif
import twocore/runtime/rt_meter

// ─────────────────────────────── fixtures ───────────────────────────────

fn module_with(
  fns: List(ir.Function),
  imports: List(ir.ImportDecl),
) -> ir.Module {
  ir.Module(
    name: "twocore@test@m",
    uses_numerics: True,
    memory: option.None,
    globals: [],
    imports: imports,
    functions: fns,
    exports: list.map(fns, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
  )
}

/// A function whose body issues a single `CallHost(capability, name, args)`.
fn call_host_fn(
  fn_name: String,
  capability: String,
  name: String,
  args: List(ir.Value),
) -> ir.Function {
  ir.Function(
    name: fn_name,
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallHost(capability, name, args),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// A plain numeric function with NO `CallHost` (used to prove the function-body `Charge`).
fn add_fn() -> ir.Function {
  ir.Function(
    name: "add",
    params: [ir.Local("p0", ir.TI64), ir.Local("p1", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.Num(ir.IAdd(ir.W64), [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `sum_to(n) == n*(n+1)/2` via a loop/break/continue (the constant-space template).
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

// ─────────────────────────────── the capability gate (fail-closed) ───────────────────────────────

/// An allowlisted `own`-stdlib call (`("std","gcd")` at the right arity) is PERMITTED, and
/// the `CallHost` node is preserved unchanged (emit_core routes it) inside the inserted
/// `Charge`. Pinned triple — state.md.
pub fn stdlib_gcd_permitted_test() {
  let m =
    module_with(
      [call_host_fn("g", "std", "gcd", [ir.Var("p0"), ir.Var("p1")])],
      [],
    )
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  let assert [f] = out.functions
  // body is wrapped in Charge; the CallHost survives unchanged within.
  let assert ir.Charge(_cost, ir.Let(["r"], rhs, _)) = f.body
  assert rhs == ir.CallHost("std", "gcd", [ir.Var("p0"), ir.Var("p1")])
}

/// A stdlib call to a name NOT on the `own` surface is rejected fail-closed with
/// `UnknownStdlibFn` (never a panic).
pub fn unknown_stdlib_fn_rejected_test() {
  let m =
    module_with([call_host_fn("g", "std", "frobnicate", [ir.Var("p0")])], [])
  assert ir_lower.lower(m, profiles.safe())
    == Error(ir_lower.UnknownStdlibFn("std", "frobnicate"))
}

/// A stdlib `gcd` call at the WRONG arity resolves to a target absent from the `rt_bif`
/// allowlist (`gcd/1`, not `gcd/2`) and is rejected fail-closed with `BifNotAllowed`.
pub fn stdlib_wrong_arity_rejected_test() {
  let m = module_with([call_host_fn("g", "std", "gcd", [ir.Var("p0")])], [])
  assert ir_lower.lower(m, profiles.safe())
    == Error(ir_lower.BifNotAllowed("gcd"))
}

/// A `CallHost` to a DECLARED host import (present in `module.imports`) is LEFT UNCHANGED —
/// it is rejected at RUN time by the deny-all host, not at build time (overview pitfall #3).
pub fn declared_host_import_permitted_test() {
  let imports = [
    ir.ImportFn("env", "log", ir.FuncType([ir.TI32], [ir.TI32])),
  ]
  let m =
    module_with([call_host_fn("u", "env", "log", [ir.Var("p0")])], imports)
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  let assert [f] = out.functions
  let assert ir.Charge(_cost, ir.Let(["r"], rhs, _)) = f.body
  assert rhs == ir.CallHost("env", "log", [ir.Var("p0")])
}

/// A `CallHost` to a capability that is NEITHER the stdlib capability NOR a declared import
/// is rejected here, fail-closed, with `ForbiddenHost` (an un-allowlisted capability with no
/// provenance).
pub fn undeclared_host_rejected_test() {
  let m = module_with([call_host_fn("e", "evil", "run", [ir.Var("p0")])], [])
  assert ir_lower.lower(m, profiles.safe())
    == Error(ir_lower.ForbiddenHost("evil", "run"))
}

// ─────────────────────────────── metering insertion (the seam) ───────────────────────────────

/// Every function body gains a `Charge(_, _)` at its head (the metering seam exists, D9).
pub fn function_body_metered_test() {
  let m = module_with([add_fn()], [])
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  let assert [f] = out.functions
  // the original body is now wrapped in a Charge; the inner body is unchanged.
  let assert ir.Charge(_cost, inner) = f.body
  assert inner == add_fn().body
}

/// A `Loop` body is wrapped in its own `Charge` so each iteration is metered, AND the
/// loop's label/params/result are untouched (so emit_core's constant-space lowering still
/// applies).
pub fn loop_body_metered_test() {
  let m = module_with([sum_to_fn()], [])
  let assert Ok(out) = ir_lower.lower(m, profiles.safe())
  let assert [f] = out.functions
  // function body: Charge(fn) wrapping the Loop, whose body is Charge(loop) wrapping the
  // original loop body.
  let assert ir.Charge(_fn_cost, ir.Loop(label, params, result, loop_body)) =
    f.body
  assert label == "go"
  assert params == sum_to_fn_params()
  assert result == [ir.TI64]
  let assert ir.Charge(_loop_cost, original_loop_body) = loop_body
  assert original_loop_body == sum_to_loop_body()
}

fn sum_to_fn_params() -> List(ir.LoopParam) {
  let assert ir.Loop(_, params, _, _) = sum_to_fn().body
  params
}

fn sum_to_loop_body() -> ir.Expr {
  let assert ir.Loop(_, _, _, body) = sum_to_fn().body
  body
}

// ─────────────────────────────── Unsafe is a pass-through (Phase-2 placeholder) ───────────────────────────────

/// Under a (non-shipping) `Unsafe` binding the pass is a no-op pass-through: no metering, no
/// gating. There is no way to obtain an `Unsafe` binding from `profiles` (fail-closed), so
/// this is only reachable by hand-constructing the binding.
pub fn unsafe_mode_passthrough_test() {
  let unsafe_binding =
    instance.Binding(..instance.safe_default(), mode: instance.Unsafe)
  let m = module_with([add_fn()], [])
  assert ir_lower.lower(m, unsafe_binding) == Ok(m)
}

// ─────────────────────────────── anti-drift cross-check (policy == rt_bif) ───────────────────────────────

/// The `own`-stdlib surface this pass resolves to MUST equal the `rt_bif` allowlist, so the
/// policy here and the allowlist in unit 09 cannot silently diverge (overview §11a). Compare
/// as sets.
pub fn stdlib_surface_matches_rt_bif_allowlist_test() {
  let resolved =
    set.from_list(ir_lower.resolved_stdlib_targets(profiles.safe()))
  let allowed = set.from_list(rt_bif.allowlist())
  assert resolved == allowed
}

// ─────────────────────────────── end-to-end: metering + results unchanged ───────────────────────────────

/// Compile `m` through the Safe pipeline (ir_lower → emit → build) and invoke `export`,
/// returning the run result and the fuel charged DURING the call (the pdict counter is
/// per-process; gleeunit runs each test synchronously in one process).
fn run_metered(
  m: ir.Module,
  export: String,
  args: List(Int),
) -> #(pipeline.RunResult, Int) {
  let assert Ok(core) = pipeline.ir_to_core(m, profiles.safe())
  let assert Ok(beam) = pipeline.core_to_beam(core, m.name)
  rt_meter.reset_fuel()
  let result = pipeline.invoke(beam, m.name, export, args)
  #(result, rt_meter.fuel_consumed())
}

/// A no-loop function charges EXACTLY once (the function-body `Charge`) per call, and the
/// metering does NOT change the result: `add(7, 35) == 42`, fuel == 1.
pub fn function_charge_counts_and_result_unchanged_test() {
  let m =
    ir.Module(..module_with([add_fn()], []), name: "twocore@test@add_metered")
  let #(result, fuel) = run_metered(m, "add", [7, 35])
  assert result == pipeline.Returned([42])
  assert fuel == 1
}

/// The constant-space loop runs WITH metering on: `sum_to(10) == 55` and
/// `sum_to(100000) == 5000050000` (the large case completes without unbounded stack growth,
/// proving the loop back-edge stayed in tail position despite the inserted `Charge`). The
/// fuel ACCUMULATES proportionally to iterations: each extra iteration adds exactly one loop
/// charge, so `fuel(100000) - fuel(10) == 100000 - 10`.
pub fn loop_constant_space_with_metering_test() {
  let m =
    ir.Module(
      ..module_with([sum_to_fn()], []),
      name: "twocore@test@sum_metered",
    )
  let #(r10, fuel10) = run_metered(m, "sum_to", [10])
  let #(r_big, fuel_big) = run_metered(m, "sum_to", [100_000])
  assert r10 == pipeline.Returned([55])
  assert r_big == pipeline.Returned([5_000_050_000])
  // accumulation is proportional to loop work (slope exactly 1 charge / iteration).
  assert fuel_big - fuel10 == 100_000 - 10
  // and the function-entry + loop-entry model: fuel(n) == n + 2.
  assert fuel10 == 12
}
