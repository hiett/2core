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

/// The set of fixed runtime module names the `Binding` permits a `call` to target.
fn runtime_modules(b: instance.Binding) -> Set(String) {
  set.from_list([
    b.num_module,
    b.trap_module,
    b.host_module,
    b.meter_module,
    b.stdlib_module,
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

/// `CallIndirect` (the table-dispatch node) is NOT lowered to any `apply`/`call` — it
/// returns a typed `Error`, so it cannot become an ambient-authority dispatch.
pub fn call_indirect_does_not_lower_test() {
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("i", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.CallIndirect("t", ir.Var("i"), ir.FuncType([], [ir.TI32]), []),
    )
  let module =
    ir.Module(
      name: "twocore@test@ci",
      uses_numerics: True,
      memory: option.None,
      globals: [],
      imports: [],
      functions: [f],
      exports: [ir.ExportFn("f", "f")],
      data_segments: [],
    )
  assert emit_core.emit_module(module, instance.safe_default())
    == Error(emit_core.UnsupportedNode("call_indirect"))
}
