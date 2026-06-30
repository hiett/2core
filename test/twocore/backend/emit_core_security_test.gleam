//// Unit 08 — codegen security-invariant test (high-level §5 / D3a).
////
//// STRUCTURAL, not by string inspection: it walks the emitted `core_erlang` AST and
//// asserts the no-ambient-authority invariant property-style. Two things must hold for
//// EVERY generated module:
////
//// 1. Every inter-module `call` (`CCall`) targets a FIXED `twocore@runtime@*` module
////    drawn from the `Binding` — there is no data-driven `call Mod:Fun(...)` of a
////    program/attacker-chosen module, and the function position is always a literal atom.
//// 2. `CallHost`/`CallIndirect`/(memory/table ops) never lower to a bare `apply` of a
////    non-runtime module atom: `CallHost` becomes a runtime `call` (deny-all host or the
////    resolved stdlib), and the out-of-scope nodes return a typed `Error` rather than
////    emitting anything. (`CApply` is structurally a same-module static call — its target
////    is an `FName`, never a computed/dynamic module — so the IR cannot synthesise an
////    ambient-authority `apply(Mod, F, Args)` at all.)
////
//// The corpus here deliberately mixes numerics, a trap, metering, a host import, a stdlib
//// call, a direct self-call, and a loop, so every kind of emitted `call` is covered.

import gleam/list
import gleam/option
import gleam/set.{type Set}
import twocore/backend/core_erlang.{
  type CExpr, type CModule, CApply, CAtom, CCall, CCase, CClause, CCons, CFun,
  CLet, CLetrec, CTuple, CValues, FunDef,
}
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance

/// The set of fixed runtime module names the `Binding` permits a `call` to target. Extended
/// in Phase 2 with the memory/table/state modules — the new stateful-op authority (D3a).
fn runtime_modules(b: instance.Binding) -> Set(String) {
  set.from_list([
    b.num_module,
    b.trap_module,
    b.host_module,
    b.meter_module,
    b.stdlib_module,
    b.mem_module,
    b.table_module,
    b.state_module,
  ])
}

/// Collect every `#(module_expr, function_expr)` of every `CCall` in `e` (recursively).
fn calls_in(e: CExpr) -> List(#(CExpr, CExpr)) {
  let here = case e {
    CCall(m, f, _) -> [#(m, f)]
    _ -> []
  }
  list.append(here, list.flat_map(children(e), calls_in))
}

/// The direct sub-expressions of a Core node (enough to reach every `CCall`).
fn children(e: CExpr) -> List(CExpr) {
  case e {
    CCall(m, f, args) -> [m, f, ..args]
    CApply(_, args) -> args
    CLet(_, arg, body) -> [arg, body]
    CLetrec(defs, body) -> [
      body,
      ..list.map(defs, fn(d) {
        let FunDef(_, v) = d
        v
      })
    ]
    CCase(arg, clauses) -> [
      arg,
      ..list.flat_map(clauses, fn(c) {
        let CClause(_, g, b) = c
        [g, b]
      })
    ]
    CFun(_, body) -> [body]
    CCons(h, t) -> [h, t]
    CTuple(xs) -> xs
    CValues(xs) -> xs
    _ -> []
  }
}

/// Every `call` in `m` targets a fixed runtime module atom (drawn from `binding`) and a
/// literal function atom.
fn assert_calls_are_runtime(m: CModule, binding: instance.Binding) {
  let allowed = runtime_modules(binding)
  let calls =
    list.flat_map(m.defs, fn(d) {
      let FunDef(_, v) = d
      calls_in(v)
    })
  list.each(calls, fn(pair) {
    let #(mod, fun) = pair
    // module position: a literal atom that is one of the binding's runtime modules.
    let assert CAtom(mod_name) = mod
    assert set.contains(allowed, mod_name) == True
    // function position: a literal atom (never program-chosen/computed).
    let assert CAtom(_) = fun
  })
}

/// A module exercising every emitted `call` kind plus a direct call and a loop.
fn mixed_module() -> ir.Module {
  let kitchen_sink =
    ir.Function(
      name: "f",
      params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Charge(
        3,
        ir.Let(
          ["s"],
          ir.Num(ir.IAdd(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
          ir.Let(
            ["q"],
            // trapping num → case + raise (trap_module call)
            ir.Num(ir.IDivS(ir.W32), [ir.Var("s"), ir.Var("p1")]),
            ir.Let(
              ["h"],
              // host import → deny-all host_module call
              ir.CallHost("env", "log", [ir.Var("q")]),
              ir.Let(
                ["g"],
                // resolved stdlib → stdlib_module call
                ir.CallHost("std", "gcd", [ir.Var("q"), ir.Var("h")]),
                ir.Let(
                  ["d"],
                  // direct self-call → apply (NOT a call)
                  ir.CallDirect("f", [ir.Var("g"), ir.Var("p1")]),
                  ir.Return([ir.Var("d")]),
                ),
              ),
            ),
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@test@sink",
    uses_numerics: True,
    memory: option.None,
    globals: [],
    imports: [],
    functions: [kitchen_sink],
    exports: [ir.ExportFn("f", "f")],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
  )
}

/// THE security-invariant test: every runtime `call` in a busy module targets a fixed
/// `twocore@runtime@*` module from the `Binding`, with a literal function atom — no
/// ambient authority (D3a).
pub fn no_ambient_authority_in_calls_test() {
  let binding = instance.safe_default()
  let assert Ok(m) = emit_core.emit_module(mixed_module(), binding)
  assert_calls_are_runtime(m, binding)
}

/// Collect every `CApply` target `FName` in `e` (recursively). A `CApply`'s module/function
/// is structurally an `FName` (a literal atom + arity) — there is NO `apply(Mod, F, Args)`
/// form in the AST — so the IR cannot synthesise an ambient-authority dynamic apply.
fn applies_in(e: CExpr) -> List(core_erlang.FName) {
  let here = case e {
    CApply(name, _) -> [name]
    _ -> []
  }
  list.append(here, list.flat_map(children(e), applies_in))
}

/// A module exercising `call_indirect` AND every memory/global/table op + size/grow, plus a
/// table/memory/global declaration with active element/data segments and a start — so the
/// security walk covers the whole new stateful authority and the generated `instantiate/0`.
fn stateful_module() -> ir.Module {
  let target =
    ir.Function(
      name: "target",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Return([ir.Var("p0")]),
    )
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        [],
        ir.MemStore(ir.MemAccess(4, False), ir.Var("p0"), ir.Var("p0"), 0),
        ir.Let(
          ["g"],
          ir.GlobalGet("g0"),
          ir.Let(
            [],
            ir.GlobalSet("g0", ir.Var("g")),
            ir.Let(
              ["ld"],
              ir.MemLoad(ir.MemAccess(4, False), ir.Var("p0"), 0, ir.TI32),
              ir.Let(
                ["sz"],
                ir.MemSize,
                ir.Let(
                  ["gr"],
                  ir.MemGrow(ir.Var("sz")),
                  ir.CallIndirect(
                    "t0",
                    ir.Var("ld"),
                    ir.FuncType([ir.TI32], [ir.TI32]),
                    [ir.Var("gr")],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    )
  ir.Module(
    name: "twocore@test@stateful",
    uses_numerics: True,
    memory: option.Some(ir.MemoryDecl(1, option.None)),
    globals: [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(0)]))],
    imports: [],
    functions: [target, f],
    exports: [ir.ExportFn("f", "f")],
    data_segments: [ir.DataSegment(ir.Values([ir.ConstI32(0)]), <<9, 9>>)],
    tables: [ir.TableDecl("t0", 4, option.None)],
    elements: [
      ir.ElementSegment("t0", ir.Values([ir.ConstI32(0)]), ["target"]),
    ],
    start: option.None,
  )
}

/// EXTENDED security invariant: a module using `call_indirect` + every memory/global/table
/// op (and the generated `instantiate/0`) still has NO ambient authority — every emitted
/// `call` targets a fixed `Binding` runtime module with a literal function atom (a).
pub fn stateful_ops_have_no_ambient_authority_test() {
  let binding = instance.safe_default()
  let assert Ok(m) = emit_core.emit_module(stateful_module(), binding)
  assert_calls_are_runtime(m, binding)
}

/// (b) No data-driven `apply`: every `CApply` in the whole module (including the
/// `call_indirect` lowering and the `instantiate/0` element closures) targets a literal
/// `FName` whose module-LOCAL function name is NEVER one of the runtime module atoms — the
/// dispatch is a closed set of compile-time-fixed `f<idx>` applies selected by a runtime
/// integer, never `apply(Mod, F, Args)` of program/runtime data.
pub fn call_indirect_dispatch_is_ambient_safe_test() {
  let binding = instance.safe_default()
  let allowed = runtime_modules(binding)
  let assert Ok(m) = emit_core.emit_module(stateful_module(), binding)
  let applies =
    list.flat_map(m.defs, fn(d) {
      let core_erlang.FunDef(_, v) = d
      applies_in(v)
    })
  // Every apply is a static local FName — its name is never a runtime module atom (an
  // apply can only reach a same-module function, never a cross-module/data-driven target).
  list.each(applies, fn(name) {
    let core_erlang.FName(n, _arity) = name
    assert set.contains(allowed, n) == False
  })
  // (c) The three call_indirect faults are DELEGATED to `rt_table` via the seam call: the
  // dispatch is one `call '<table_module>':'call_indirect'(Idx, TypeTag, Args)` whose
  // `{error,E}` arm raises via `rt_trap` — emit_core emits no per-fault branching itself.
  assert has_call(m, binding.table_module, "call_indirect")
  assert has_call(m, binding.table_module, "init_elem")
  assert has_call(m, binding.trap_module, "raise")
}

/// True iff some def in `m` contains a `call '<module>':'<fun>'(…)`.
fn has_call(m: CModule, module: String, fun: String) -> Bool {
  list.any(m.defs, fn(d) {
    let core_erlang.FunDef(_, v) = d
    list.any(calls_in(v), fn(pair) {
      let #(mod, f) = pair
      mod == CAtom(module) && f == CAtom(fun)
    })
  })
}
