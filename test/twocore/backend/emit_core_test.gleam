//// Unit 08 — `emit_core` boundary tests.
////
//// These assert the IR→`.core` lowering against the high-level §5 mapping / the unit-08
//// doc's per-construct table and the two VERIFIED grounded facts — NOT against "whatever
//// the code currently emits" (no change-detector goldens). Each test pattern-matches the
//// emitted `core_erlang` AST and asserts the structural shape the spec/doc requires:
//// a `Loop` is a `letrec` whose body tail-applies the loop head; an `If` is a `case`
//// matching the i32 condition with `when 'true'` on every clause; a trapping `Num` is the
//// `{ok,_}`/`{error,_}`-`case`-and-`raise`; `Trap`/`CallHost`/`Charge` route through the
//// fixed `Binding` modules; and the `NumOp → rt_num` name table actually names functions
//// `rt_num` exports.

import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option
import twocore/backend/core_erlang.{
  type CExpr, CApply, CAtom, CBinary, CCall, CCase, CClause, CCons, CFun, CInt,
  CLet, CLetrec, CNil, CTuple, CVar, FName, FunDef, PAtom, PCons, PInt, PNil,
  PTuple, PVar,
}
import twocore/backend/emit_core
import twocore/ir
import twocore/runtime/instance
import twocore/runtime/rt_num

// `erlang:function_exported/3` — True iff `Module:Function/Arity` is a loaded export. Used
// to tie the `NumOp → rt_num` name table and the Gleam→Erlang mangling to the real
// artefact (verified fact 1): a mangling/name drift makes the export vanish and fails here.
@external(erlang, "erlang", "function_exported")
fn function_exported(module: Atom, function: Atom, arity: Int) -> Bool

// ───────────────────────────── helpers ─────────────────────────────

/// The Phase-1 Safe binding (the fixed `twocore@runtime@*` module table).
fn binding() -> instance.Binding {
  instance.safe_default()
}

/// Wrap a single function in a numerics-on, memory-off module exporting it by its own name.
fn module_with(f: ir.Function) -> ir.Module {
  ir.Module(
    name: "twocore@test@" <> f.name,
    uses_numerics: True,
    memory: option.None,
    globals: [],
    imports: [],
    functions: [f],
    exports: [ir.ExportFn(f.name, f.name)],
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
  )
}

/// Emit `module` and return the Core body expression of function `name`.
fn body_of(module: ir.Module, name: String) -> CExpr {
  let assert Ok(m) = emit_core.emit_module(module, binding())
  let assert Ok(FunDef(_, CFun(_, body))) =
    list.find(m.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == name
    })
  body
}

/// True iff `e` (recursively) contains an `apply` of the function atom `name`.
fn applies_to(e: CExpr, name: String) -> Bool {
  case e {
    CApply(FName(n, _), args) ->
      n == name || list.any(args, applies_to(_, name))
    CCall(m, f, args) ->
      applies_to(m, name)
      || applies_to(f, name)
      || list.any(args, applies_to(_, name))
    CLet(_, arg, body) -> applies_to(arg, name) || applies_to(body, name)
    CLetrec(defs, body) ->
      list.any(defs, fn(d) {
        let FunDef(_, v) = d
        applies_to(v, name)
      })
      || applies_to(body, name)
    CCase(arg, clauses) ->
      applies_to(arg, name)
      || list.any(clauses, fn(c) {
        let CClause(_, g, b) = c
        applies_to(g, name) || applies_to(b, name)
      })
    CFun(_, b) -> applies_to(b, name)
    CCons(h, t) -> applies_to(h, name) || applies_to(t, name)
    CTuple(xs) -> list.any(xs, applies_to(_, name))
    _ -> False
  }
}

// ───────────────────────────── Let / Return / Num (add) ─────────────────────────────

fn add_fn() -> ir.Function {
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
  )
}

/// `Let(names, rhs, body)` → `let <names> = <rhs> in <body>`; `Num(IAdd(W32))` routes
/// through `num_module:i32_add`; tail `Return([r])` is the bare value (a 1-value list).
pub fn let_num_return_test() {
  let b = binding()
  let assert CLet(
    ["r"],
    CCall(CAtom(num), CAtom("i32_add"), [CVar("p0"), CVar("p1")]),
    CVar("r"),
  ) = body_of(module_with(add_fn()), "add")
  assert num == b.num_module
}

// ───────────────────────────── If → case on i32 ─────────────────────────────

fn if_fn() -> ir.Function {
  ir.Function(
    name: "pick",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.If(
      cond: ir.Var("p0"),
      result: [ir.TI32],
      then_branch: ir.Return([ir.ConstI32(1)]),
      else_branch: ir.Return([ir.ConstI32(0)]),
    ),
  )
}

/// `If(cond, _, t, e)` → `case Cond of <0> -> e; <_> -> t end`, every clause guarded by
/// `when 'true'`. (cond is an i32 truth value; matching `0` = false → else, else → then.)
pub fn if_to_case_test() {
  let assert CCase(
    CVar("p0"),
    [
      CClause([PInt(0)], CAtom("true"), CInt(0)),
      CClause([PVar(_)], CAtom("true"), CInt(1)),
    ],
  ) = body_of(module_with(if_fn()), "pick")
}

// ───────────────────────────── Loop + Continue + Break (sum_to) ─────────────────────────────

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

/// `Loop` → the verified §5 template: `letrec 'L'/arity = fun(params…) -> <body>` applied
/// to the inits; `Continue` is a tail `apply 'L'` (the back-edge → constant space); the
/// fall-through/`Break` exit (here, in tail position) yields the bare value list.
pub fn loop_is_tail_recursive_letrec_test() {
  let assert CLetrec(
    [FunDef(FName(lname, 2), CFun(["i", "acc"], lbody))],
    CApply(FName(entry, 2), [CInt(1), CInt(0)]),
  ) = body_of(module_with(sum_to_fn()), "sum_to")
  // The letrec head is what `apply` enters.
  assert entry == lname
  // The body's `continue` is a tail self-apply of the same head → constant space.
  assert applies_to(lbody, lname)
  // The body computes the loop condition, then `case`s on it: `<0>` (false) breaks with the
  // bare accumulator (no join point, since the exit is in tail position / KReturn).
  let assert CLet(
    ["cond"],
    CCall(_, CAtom("i64_le_u"), _),
    CCase(
      CVar("cond"),
      [
        CClause([PInt(0)], CAtom("true"), CVar("acc")),
        CClause([PVar(_)], CAtom("true"), _),
      ],
    ),
  ) = lbody
}

// ───────────────────────────── Block + Break → forward join point ─────────────────────────────

fn block_fn() -> ir.Function {
  ir.Function(
    name: "blk",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    // bind the block result so the continuation is non-trivial → materialised join point.
    body: ir.Let(
      ["x"],
      ir.Block("b", [ir.TI32], ir.Break("b", [ir.Var("p0")])),
      ir.Return([ir.Var("x")]),
    ),
  )
}

/// `Block(label, _, body)` → a forward continuation: the code after the block becomes a
/// `letrec` join point, and `Break(label, vs)` tail-applies it.
pub fn block_break_is_join_point_test() {
  let assert CLetrec(
    [FunDef(FName(jname, 1), CFun(["x"], CVar("x")))],
    CApply(FName(target, 1), [CVar("p0")]),
  ) = body_of(module_with(block_fn()), "blk")
  assert target == jname
}

// ───────────────────────────── Switch → case + default ─────────────────────────────

fn switch_fn() -> ir.Function {
  ir.Function(
    name: "sw",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Switch(
      selector: ir.Var("p0"),
      result: [ir.TI32],
      arms: [
        ir.SwitchArm(0, ir.Return([ir.ConstI32(10)])),
        ir.SwitchArm(1, ir.Return([ir.ConstI32(11)])),
      ],
      default: ir.Return([ir.ConstI32(99)]),
    ),
  )
}

/// `Switch(sel, _, arms, default)` → `case Sel of` one `<match>` clause per arm and a
/// trailing wildcard default clause; every clause guarded by `when 'true'`.
pub fn switch_to_case_test() {
  let assert CCase(
    CVar("p0"),
    [
      CClause([PInt(0)], CAtom("true"), CInt(10)),
      CClause([PInt(1)], CAtom("true"), CInt(11)),
      CClause([PVar(_)], CAtom("true"), CInt(99)),
    ],
  ) = body_of(module_with(switch_fn()), "sw")
}

// ───────────────────────────── CallDirect → apply ─────────────────────────────

fn call_direct_fn() -> ir.Function {
  ir.Function(
    name: "rec",
    params: [ir.Local("p0", ir.TI64)],
    result: [ir.TI64],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallDirect("rec", [ir.Var("p0")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// `CallDirect(fn, args)` → `apply 'fn'/arity(args)` of the program's own static function
/// name (D3a-safe — an `apply`, never a runtime `call` of program data).
pub fn call_direct_to_apply_test() {
  let assert CLet(["r"], CApply(FName("rec", 1), [CVar("p0")]), CVar("r")) =
    body_of(module_with(call_direct_fn()), "rec")
}

// ───────────────────────────── CallHost — two fates ─────────────────────────────

fn host_import_fn() -> ir.Function {
  ir.Function(
    name: "useimport",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["r"],
      ir.CallHost("env", "log", [ir.Var("p0")]),
      ir.Return([ir.Var("r")]),
    ),
  )
}

/// A genuine host import → the deny-all `call '<host_module>':'call_host'(Cap, Name,
/// [Args…])` (Cap/Name as atoms; args as a proper Core list).
pub fn call_host_import_is_deny_all_test() {
  let b = binding()
  let assert CLet(
    ["r"],
    CCall(
      CAtom(host),
      CAtom("call_host"),
      [CAtom("env"), CAtom("log"), CCons(CVar("p0"), CNil)],
    ),
    CVar("r"),
  ) = body_of(module_with(host_import_fn()), "useimport")
  assert host == b.host_module
}

fn stdlib_fn() -> ir.Function {
  ir.Function(
    name: "g",
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

/// A resolved `own`-stdlib triple (`("std","gcd")`) → a DIRECT
/// `call '<stdlib_module>':'gcd'(Args…)` (args spread; does not pass through the host).
pub fn call_host_stdlib_is_direct_test() {
  let b = binding()
  let assert CLet(
    ["r"],
    CCall(CAtom(std), CAtom("gcd"), [CVar("p0"), CVar("p1")]),
    CVar("r"),
  ) = body_of(module_with(stdlib_fn()), "g")
  assert std == b.stdlib_module
}

// ───────────────────────────── Trap → raise ─────────────────────────────

fn trap_fn() -> ir.Function {
  ir.Function(
    name: "boom",
    params: [],
    result: [ir.TI32],
    locals: [],
    body: ir.Trap(ir.Unreachable),
  )
}

/// `Trap(reason)` → `call '<trap_module>':'raise'(<snake_atom>)`.
pub fn trap_to_raise_test() {
  let b = binding()
  let assert CCall(CAtom(trap), CAtom("raise"), [CAtom("unreachable")]) =
    body_of(module_with(trap_fn()), "boom")
  assert trap == b.trap_module
}

// ───────────────────────────── trapping Num → case + raise ─────────────────────────────

fn div_fn() -> ir.Function {
  ir.Function(
    name: "d",
    params: [ir.Local("p0", ir.TI32), ir.Local("p1", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Let(
      ["q"],
      ir.Num(ir.IDivS(ir.W32), [ir.Var("p0"), ir.Var("p1")]),
      ir.Return([ir.Var("q")]),
    ),
  )
}

/// A trapping `Num` (`IDivS`) → `let <R> = case call '<num>':'i32_div_s'(A,B) of
/// <{'ok',X}> -> X <{'error',E}> -> call '<trap>':'raise'(E) end in …` — the
/// Result-`case`-and-`raise` shape, reduced to ONE bound value and threaded on.
///
/// Both `case` arms yield exactly one value (the unwrapped `X`, or the never-returning
/// `raise`), so the shape is arity-correct in *any* surrounding context — including a
/// 0-result function, where inlining the continuation into only the `ok` arm would make
/// the two arms disagree on value-list arity (a Core "return count mismatch").
pub fn trapping_num_is_case_and_raise_test() {
  let b = binding()
  let assert CLet(
    [_r],
    CCase(
      CCall(CAtom(num), CAtom("i32_div_s"), [CVar("p0"), CVar("p1")]),
      [
        CClause([PTuple([PAtom("ok"), PVar(x)])], CAtom("true"), CVar(x2)),
        CClause(
          [PTuple([PAtom("error"), PVar(e)])],
          CAtom("true"),
          CCall(CAtom(trap), CAtom("raise"), [CVar(e2)]),
        ),
      ],
    ),
    _threaded,
  ) = body_of(module_with(div_fn()), "d")
  assert num == b.num_module
  assert trap == b.trap_module
  // the `{'ok', X}` arm yields exactly the matched value X (the unwrapped result).
  assert x == x2
  // the raised payload is exactly the matched `{'error', E}` value.
  assert e == e2
}

// ───────────────────────────── Charge → metering seam ─────────────────────────────

fn charge_fn() -> ir.Function {
  ir.Function(
    name: "metered",
    params: [ir.Local("p0", ir.TI32)],
    result: [ir.TI32],
    locals: [],
    body: ir.Charge(7, ir.Return([ir.Var("p0")])),
  )
}

/// `Charge(cost, body)` → `let _ = call '<meter_module>':'charge'(Cost) in <body>` (the
/// seam exists; the impl is unit 09's fuel counter).
pub fn charge_is_metering_seam_test() {
  let b = binding()
  let assert CLet(
    [_],
    CCall(CAtom(meter), CAtom("charge"), [CInt(7)]),
    CVar("p0"),
  ) = body_of(module_with(charge_fn()), "metered")
  assert meter == b.meter_module
}

// ───────────────────────────── Gleam→Erlang mangling golden (fact 1) ─────────────────────────────

/// VERIFIED fact 1: the Gleam module `twocore/runtime/rt_num` compiles to Erlang module
/// `twocore@runtime@rt_num` and exports `i32_add/2`. The `Binding` already carries that
/// mangled name, and `emit_core` emits it verbatim — so a future Gleam mangling change
/// that breaks this assertion would be caught here BEFORE it silently poisons codegen.
pub fn gleam_mangling_golden_test() {
  // Force the module to be loaded so `function_exported` can see it.
  assert rt_num.i32_add(40, 2) == 42
  assert instance.safe_default().num_module == "twocore@runtime@rt_num"
  assert function_exported(
      atom.create("twocore@runtime@rt_num"),
      atom.create("i32_add"),
      2,
    )
    == True
}

/// VERIFIED fact 2: the PascalCase→snake_case wrapper (the spelling Gleam gives a 0-field
/// constructor's runtime atom). A wrong spelling here produces a `raise`/`case` that never
/// matches and fails silently at run time, so it is pinned with a golden.
pub fn pascal_to_snake_golden_test() {
  assert emit_core.pascal_to_snake("IntDivByZero") == "int_div_by_zero"
  assert emit_core.pascal_to_snake("IntOverflow") == "int_overflow"
  assert emit_core.pascal_to_snake("Unreachable") == "unreachable"
  assert emit_core.pascal_to_snake("MemoryOutOfBounds")
    == "memory_out_of_bounds"
  assert emit_core.pascal_to_snake("IndirectCallTypeMismatch")
    == "indirect_call_type_mismatch"
}

/// `trap_reason_atom` maps every `TrapReason` to the atom `rt_trap:raise/1` receives.
pub fn trap_reason_atom_golden_test() {
  assert emit_core.trap_reason_atom(ir.IntDivByZero) == "int_div_by_zero"
  assert emit_core.trap_reason_atom(ir.IntOverflow) == "int_overflow"
  assert emit_core.trap_reason_atom(ir.Unreachable) == "unreachable"
  assert emit_core.trap_reason_atom(ir.IndirectCallTypeMismatch)
    == "indirect_call_type_mismatch"
  assert emit_core.trap_reason_atom(ir.MemoryOutOfBounds)
    == "memory_out_of_bounds"
}

// ───────────────────────────── NumOp → rt_num name table (tied to rt_num) ─────────────────────────────

/// Every `NumOp` name `emit_core` emits MUST name a function `rt_num` actually exports
/// (with the right arity). This ties the chokepoint table objectively to the frozen
/// `rt_num` signatures (the spec for this seam), not to the emitter's own output: a
/// spelling drift on either side fails here.
pub fn num_op_name_matches_rt_num_test() {
  // Force `rt_num` loaded.
  assert rt_num.i32_add(1, 1) == 2
  let m = atom.create("twocore@runtime@rt_num")
  // #(op, arity) — a representative spread covering binary, unary, trapping, i64, floats.
  let cases = [
    #(ir.IAdd(ir.W32), 2),
    #(ir.ISub(ir.W64), 2),
    #(ir.IMul(ir.W32), 2),
    #(ir.IDivS(ir.W32), 2),
    #(ir.IDivU(ir.W64), 2),
    #(ir.IRemS(ir.W32), 2),
    #(ir.IRemU(ir.W64), 2),
    #(ir.IAnd(ir.W32), 2),
    #(ir.IOr(ir.W64), 2),
    #(ir.IXor(ir.W32), 2),
    #(ir.IShl(ir.W32), 2),
    #(ir.IShrS(ir.W64), 2),
    #(ir.IShrU(ir.W64), 2),
    #(ir.IRotl(ir.W32), 2),
    #(ir.IRotr(ir.W64), 2),
    #(ir.IClz(ir.W32), 1),
    #(ir.ICtz(ir.W64), 1),
    #(ir.IPopcnt(ir.W32), 1),
    #(ir.IEqz(ir.W64), 1),
    #(ir.IEq(ir.W32), 2),
    #(ir.INe(ir.W64), 2),
    #(ir.ILtS(ir.W32), 2),
    #(ir.ILtU(ir.W64), 2),
    #(ir.IGtS(ir.W32), 2),
    #(ir.IGtU(ir.W64), 2),
    #(ir.ILeS(ir.W32), 2),
    #(ir.ILeU(ir.W64), 2),
    #(ir.IGeS(ir.W32), 2),
    #(ir.IGeU(ir.W64), 2),
    #(ir.FAdd(ir.FW32), 2),
    #(ir.FSub(ir.FW64), 2),
    #(ir.FMul(ir.FW32), 2),
    #(ir.FDiv(ir.FW64), 2),
    #(ir.FMin(ir.FW32), 2),
    #(ir.FMax(ir.FW64), 2),
  ]
  list.each(cases, fn(c) {
    let #(op, arity) = c
    assert function_exported(m, atom.create(emit_core.num_op_name(op)), arity)
      == True
  })
}

// ───────────────────────────── Phase-2 stateful-op goldens (the seam) ─────────────────────────────

/// Build a single-function module whose body is exactly `body` (tail position), with the
/// given params/result, exported by name. Lets the stateful-op shape be asserted directly.
fn op_module(
  name: String,
  params: List(ir.Local),
  result: List(ir.ValType),
  body: ir.Expr,
) -> ir.Module {
  module_with(ir.Function(
    name: name,
    params: params,
    result: result,
    locals: [],
    body: body,
  ))
}

/// `MemSize` → a bare `call '<mem_module>':'size'()` (an i32; no trap).
pub fn mem_size_is_bare_call_test() {
  let b = binding()
  let assert CCall(CAtom(mem), CAtom("size"), []) =
    body_of(op_module("f", [], [ir.TI32], ir.MemSize), "f")
  assert mem == b.mem_module
}

/// `MemGrow(delta)` → a bare `call '<mem_module>':'grow'(Delta)` (i32; effectful).
pub fn mem_grow_is_bare_call_test() {
  let b = binding()
  let assert CCall(CAtom(mem), CAtom("grow"), [CVar("d")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("d", ir.TI32)],
        [ir.TI32],
        ir.MemGrow(ir.Var("d")),
      ),
      "f",
    )
  assert mem == b.mem_module
}

/// `MemLoad(MemAccess(bytes,signed), addr, off, result)` → a trapping `Result`: a `case`
/// over `call '<mem_module>':'load'(Bytes, Signed, ResultWidth, Addr, Off)` raising on
/// `{error,_}`. `i32.load8_s` walks to `Signed='true'` + `ResultWidth=32`.
pub fn mem_load_is_trapping_case_test() {
  let b = binding()
  let assert CLet(
    [r],
    CCase(
      CCall(
        CAtom(mem),
        CAtom("load"),
        [CInt(1), CAtom("true"), CInt(32), CVar("a"), CInt(8)],
      ),
      [
        CClause([PTuple([PAtom("ok"), PVar(x)])], CAtom("true"), CVar(x2)),
        CClause(
          [PTuple([PAtom("error"), PVar(e)])],
          CAtom("true"),
          CCall(CAtom(trap), CAtom("raise"), [CVar(e2)]),
        ),
      ],
    ),
    CVar(r2),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TI32)],
        [ir.TI32],
        ir.MemLoad(ir.MemAccess(1, True), ir.Var("a"), 8, ir.TI32),
      ),
      "f",
    )
  assert mem == b.mem_module
  assert trap == b.trap_module
  assert x == x2
  assert e == e2
  assert r == r2
}

/// `i64.load8_s` differs from `i32.load8_s` ONLY in the emitted `ResultWidth` (64 vs 32) —
/// same `bytes`+`signed` — confirming `result` disambiguates the sign-extension width (E2).
pub fn mem_load_result_width_disambiguates_test() {
  let assert CLet(_, CCase(CCall(_, _, [_, _, CInt(w32), ..]), _), _) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TI32)],
        [ir.TI32],
        ir.MemLoad(ir.MemAccess(1, True), ir.Var("a"), 0, ir.TI32),
      ),
      "f",
    )
  let assert CLet(_, CCase(CCall(_, _, [_, _, CInt(w64), ..]), _), _) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TI32)],
        [ir.TI64],
        ir.MemLoad(ir.MemAccess(1, True), ir.Var("a"), 0, ir.TI64),
      ),
      "f",
    )
  assert w32 == 32
  assert w64 == 64
}

/// `MemStore` → a ZERO-RESULT ordered effect: `let <_> = <case over
/// call '<mem_module>':'store'(Bytes, Addr, Val, Off)> in <rest>`, the `case` reduced to a
/// single discardable value (`{ok,_}`→`'ok'`, `{error,E}`→`raise`). The store sequences
/// before the rest (non-DCE) with eval order addr → value → store.
pub fn mem_store_is_ordered_effect_test() {
  let b = binding()
  let assert CLet(
    [_g],
    CCase(
      CCall(
        CAtom(mem),
        CAtom("store"),
        [CInt(4), CVar("a"), CVar("v"), CInt(0)],
      ),
      [
        CClause([PTuple([PAtom("ok"), PVar(_)])], CAtom("true"), CAtom("ok")),
        CClause(
          [PTuple([PAtom("error"), PVar(e)])],
          CAtom("true"),
          CCall(CAtom(trap), CAtom("raise"), [CVar(e2)]),
        ),
      ],
    ),
    CAtom("ok"),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TI32), ir.Local("v", ir.TI32)],
        [],
        ir.MemStore(ir.MemAccess(4, False), ir.Var("a"), ir.Var("v"), 0),
      ),
      "f",
    )
  assert mem == b.mem_module
  assert trap == b.trap_module
  assert e == e2
}

/// `GlobalGet(name)` → a bare `call '<state_module>':'global_get'(NameBin)` where `NameBin`
/// is a Core binary STRING literal (`<<"g0">>`), not an atom (the frozen `rt_state` head
/// takes a `String`/binary).
pub fn global_get_is_binary_name_call_test() {
  let b = binding()
  let assert CCall(CAtom(state), CAtom("global_get"), [CBinary(_)]) =
    body_of(op_module("f", [], [ir.TI32], ir.GlobalGet("g0")), "f")
  assert state == b.state_module
}

/// `GlobalSet(name, value)` → a ZERO-RESULT ordered effect: `let <_> =
/// call '<state_module>':'global_set'(NameBin, Val) in <rest>` (pure — no trap `case`).
pub fn global_set_is_ordered_effect_test() {
  let b = binding()
  let assert CLet(
    [_g],
    CCall(CAtom(state), CAtom("global_set"), [CBinary(_), CVar("v")]),
    CAtom("ok"),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("v", ir.TI32)],
        [],
        ir.GlobalSet("g0", ir.Var("v")),
      ),
      "f",
    )
  assert state == b.state_module
}

/// `CallIndirect(table, index, ty, args)` → a `case` over `call '<table_module>':
/// 'call_indirect'(Idx, TypeTag, ArgList)` raising on `{error,_}`, where `TypeTag` is the
/// compile-time canonical `{[params],[results]}` term and `ArgList` is a proper Core list.
/// The `{ok,V}` result list is then unpacked (here r=1 → `[V]`).
pub fn call_indirect_is_seam_dispatch_test() {
  let b = binding()
  let assert CLet(
    [lv],
    CCase(
      CCall(
        CAtom(table),
        CAtom("call_indirect"),
        [
          CVar("i"),
          CTuple([CCons(CAtom("i32"), CNil), CCons(CAtom("i32"), CNil)]),
          CCons(CVar("x"), CNil),
        ],
      ),
      [
        CClause([PTuple([PAtom("ok"), PVar(_)])], CAtom("true"), CVar(_)),
        CClause(
          [PTuple([PAtom("error"), PVar(_)])],
          CAtom("true"),
          CCall(CAtom(trap), CAtom("raise"), [CVar(_)]),
        ),
      ],
    ),
    CCase(CVar(lv2), [CClause([PCons(PVar(n), PNil)], CAtom("true"), CVar(n2))]),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("i", ir.TI32), ir.Local("x", ir.TI32)],
        [ir.TI32],
        ir.CallIndirect("t0", ir.Var("i"), ir.FuncType([ir.TI32], [ir.TI32]), [
          ir.Var("x"),
        ]),
      ),
      "f",
    )
  assert table == b.table_module
  assert trap == b.trap_module
  assert lv == lv2
  assert n == n2
}

/// A TRAPPING `Convert` (`TruncS`) → the `case`-and-`raise` shape over
/// `call '<num_module>':'i32_trunc_f32_s'(A)` (NOT a bare call) — `trunc_f*` traps NaN/±Inf/
/// out-of-range (`exec/numerics`).
pub fn trapping_trunc_is_case_and_raise_test() {
  let b = binding()
  let assert CLet(
    [r],
    CCase(
      CCall(CAtom(num), CAtom("i32_trunc_f32_s"), [CVar("x")]),
      [
        CClause([PTuple([PAtom("ok"), PVar(_)])], CAtom("true"), CVar(_)),
        CClause(
          [PTuple([PAtom("error"), PVar(_)])],
          CAtom("true"),
          CCall(CAtom(_), CAtom("raise"), [CVar(_)]),
        ),
      ],
    ),
    CVar(r2),
  ) =
    body_of(
      op_module(
        "f",
        [ir.Local("x", ir.TF32)],
        [ir.TI32],
        ir.Convert(ir.TruncS(ir.FW32, ir.W32), ir.Var("x")),
      ),
      "f",
    )
  assert num == b.num_module
  assert r == r2
}

/// A TOTAL `Convert` (`ConvertS`/`F32DemoteF64`/`F64PromoteF32`) → a bare `num_module` call
/// (never wrapped in a trap `case` — these conversions never trap).
pub fn total_convert_is_bare_call_test() {
  let b = binding()
  let assert CCall(CAtom(num), CAtom("f32_convert_i32_s"), [CVar("x")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("x", ir.TI32)],
        [ir.TF32],
        ir.Convert(ir.ConvertS(ir.W32, ir.FW32), ir.Var("x")),
      ),
      "f",
    )
  assert num == b.num_module
  let assert CCall(CAtom(_), CAtom("f32_demote_f64"), [CVar("x")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("x", ir.TF64)],
        [ir.TF32],
        ir.Convert(ir.F32DemoteF64, ir.Var("x")),
      ),
      "f",
    )
  let assert CCall(CAtom(_), CAtom("f64_promote_f32"), [CVar("x")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("x", ir.TF32)],
        [ir.TF64],
        ir.Convert(ir.F64PromoteF32, ir.Var("x")),
      ),
      "f",
    )
}

/// A float comparison (`FLt`) → a bare `call '<num_module>':'f32_lt'(A,B)` (an i32 0/1).
pub fn float_compare_is_bare_call_test() {
  let b = binding()
  let assert CCall(CAtom(num), CAtom("f32_lt"), [CVar("a"), CVar("b")]) =
    body_of(
      op_module(
        "f",
        [ir.Local("a", ir.TF32), ir.Local("b", ir.TF32)],
        [ir.TI32],
        ir.Num(ir.FLt(ir.FW32), [ir.Var("a"), ir.Var("b")]),
      ),
      "f",
    )
  assert num == b.num_module
}

// ───────────────────────────── the instantiate/0 entry golden ─────────────────────────────

/// A module exercising the whole instantiation contract: a memory + an active data segment,
/// a table + an active element segment (referencing `elemfn`), a global with a constant
/// init, and a `start` function.
fn full_module() -> ir.Module {
  let elemfn =
    ir.Function(
      name: "elemfn",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Return([ir.Var("p0")]),
    )
  let initfn =
    ir.Function(
      name: "init",
      params: [],
      result: [],
      locals: [],
      body: ir.Values([]),
    )
  ir.Module(
    name: "twocore@test@full",
    uses_numerics: True,
    memory: option.Some(ir.MemoryDecl(1, option.Some(2))),
    globals: [ir.GlobalDecl("g0", ir.TI32, True, ir.Values([ir.ConstI32(42)]))],
    imports: [],
    functions: [elemfn, initfn],
    exports: [],
    data_segments: [ir.DataSegment(ir.Values([ir.ConstI32(0)]), <<1, 2, 3>>)],
    tables: [ir.TableDecl("t0", 4, option.None)],
    elements: [ir.ElementSegment("t0", ir.Values([ir.ConstI32(0)]), ["elemfn"])],
    start: option.Some("init"),
  )
}

/// True iff `e` (recursively) contains a `call '<module>':'<fn>'(…)`.
fn contains_call(e: CExpr, module: String, fun: String) -> Bool {
  case e {
    CCall(CAtom(m), CAtom(f), args) ->
      { m == module && f == fun }
      || list.any(args, contains_call(_, module, fun))
    CCall(m, f, args) ->
      contains_call(m, module, fun)
      || contains_call(f, module, fun)
      || list.any(args, contains_call(_, module, fun))
    CLet(_, a, b) ->
      contains_call(a, module, fun) || contains_call(b, module, fun)
    CLetrec(defs, b) ->
      list.any(defs, fn(d) {
        let FunDef(_, v) = d
        contains_call(v, module, fun)
      })
      || contains_call(b, module, fun)
    CCase(a, cs) ->
      contains_call(a, module, fun)
      || list.any(cs, fn(c) {
        let CClause(_, g, bd) = c
        contains_call(g, module, fun) || contains_call(bd, module, fun)
      })
    CFun(_, b) -> contains_call(b, module, fun)
    CCons(h, t) ->
      contains_call(h, module, fun) || contains_call(t, module, fun)
    CTuple(xs) -> list.any(xs, contains_call(_, module, fun))
    _ -> False
  }
}

/// THE `instantiate/0` golden: it is exported, and its body sequences (in order)
/// `seed` → `init_elem` → `init_data` → `apply 'init'/0` → `'ok'`, each init step a
/// trap-at-instantiation `case`, with the element entry a `CFun`-wrapped STATIC `apply` of
/// `elemfn` (no dynamic apply).
pub fn instantiate_entry_golden_test() {
  let b = binding()
  let assert Ok(cm) = emit_core.emit_module(full_module(), b)
  // Exported as `instantiate/0`.
  assert list.contains(cm.exports, FName("instantiate", 0))
  let assert Ok(FunDef(_, CFun([], body))) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "instantiate"
    })
  // Step 1: seed — `{state_decl, fresh(...), [{<<"g0">>,42}], new(...)}`.
  let assert CLet([_], seed_rhs, rest1) = body
  let assert CCall(
    CAtom(state),
    CAtom("seed"),
    [CTuple([CAtom("state_decl"), mem_fresh, globals, table_new])],
  ) = seed_rhs
  assert state == b.state_module
  let assert CCall(CAtom(_), CAtom("fresh"), [CInt(1), _, CInt(65_536)]) =
    mem_fresh
  let assert CCall(CAtom(_), CAtom("new"), [CInt(4), _]) = table_new
  let assert CCons(CTuple([CBinary(_), CInt(42)]), CNil) = globals
  // Step 2: element segment BEFORE data segment, each a trap `case` over its seam call.
  let assert CLet([_], elem_rhs, rest2) = rest1
  assert contains_call(elem_rhs, b.table_module, "init_elem")
  // The element entry is a build-controlled closure that STATICALLY applies `elemfn`.
  assert applies_to(elem_rhs, "elemfn")
  // Step 3: data segment.
  let assert CLet([_], data_rhs, rest3) = rest2
  assert contains_call(data_rhs, b.mem_module, "init_data")
  // Step 4: the start function, applied statically, then `'ok'`.
  let assert CLet([_], CApply(FName("init", 0), []), CAtom("ok")) = rest3
}

// ───────────────────────────── fail-closed error paths (never panic) ─────────────────────────────

/// The remaining out-of-scope IR nodes return a typed `EmitError` — never a panic (D4
/// fail-closed). Phase 2 lowers the stateful ops + numeric `Convert`s, so only the term
/// layer (`TermOp`) and the four term↔numeric boxing `Convert`s stay unsupported.
pub fn out_of_scope_nodes_error_test() {
  assert emit_one(ir.TermOp(ir.MakeTuple, [ir.Var("a")]))
    == Error(emit_core.UnsupportedNode("term_op"))
  assert emit_one(ir.Convert(ir.BoxInt(ir.W32), ir.Var("a")))
    == Error(emit_core.UnsupportedNode("box_int"))
  assert emit_one(ir.Convert(ir.UnboxInt(ir.W32), ir.Var("a")))
    == Error(emit_core.UnsupportedNode("unbox_int"))
  assert emit_one(ir.Convert(ir.BoxFloat(ir.FW32), ir.Var("a")))
    == Error(emit_core.UnsupportedNode("box_float"))
  assert emit_one(ir.Convert(ir.UnboxFloat(ir.FW32), ir.Var("a")))
    == Error(emit_core.UnsupportedNode("unbox_float"))
}

/// A `CallDirect` to an undefined function is `Error(UnknownFunction)`.
pub fn unknown_function_error_test() {
  let f =
    ir.Function(
      name: "caller",
      params: [],
      result: [ir.TI32],
      locals: [],
      body: ir.CallDirect("nope", []),
    )
  assert emit_core.emit_module(module_with(f), binding())
    == Error(emit_core.UnknownFunction("nope"))
}

/// When an `ExportFn`'s external `export_name` differs from the internal `fn_name`, the
/// export list references `export_name` and a forwarding wrapper `'export_name'/arity =
/// fun(A…) -> apply 'fn_name'/arity(A…)` is emitted (Core Erlang exports a function by its
/// own name).
pub fn export_alias_wrapper_test() {
  let f =
    ir.Function(
      name: "f3",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Return([ir.Var("p0")]),
    )
  let m =
    ir.Module(
      name: "twocore@test@alias",
      uses_numerics: True,
      memory: option.None,
      globals: [],
      imports: [],
      functions: [f],
      exports: [ir.ExportFn("main", "f3")],
      data_segments: [],
      tables: [],
      elements: [],
      start: option.None,
    )
  let assert Ok(cm) = emit_core.emit_module(m, binding())
  // The external name/arity is exported …
  assert list.contains(cm.exports, FName("main", 1))
  // … via a wrapper that forwards to the internal function.
  let assert Ok(FunDef(
    FName("main", 1),
    CFun([_], CApply(FName("f3", 1), [CVar(_)])),
  )) =
    list.find(cm.defs, fn(d) {
      let FunDef(FName(n, _), _) = d
      n == "main"
    })
}

/// Emit a one-function module whose body is `expr`, returning the module-level result.
fn emit_one(expr: ir.Expr) -> Result(core_erlang.CModule, emit_core.EmitError) {
  let f =
    ir.Function(
      name: "f",
      params: [ir.Local("a", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: expr,
    )
  emit_core.emit_module(module_with(f), binding())
}
