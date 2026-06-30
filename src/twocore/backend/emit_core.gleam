//// Unit 08 — `emit_core` — lower the shared IR to a Core Erlang AST.
////
//// This is the **backend** and the **binding chokepoint** (D3b). It walks an
//// `ir.Module` and produces a `core_erlang.CModule` (unit 03's AST), which unit 04's
//// `build_beam` compiles to a loadable `.beam`. Nothing here knows about WASM — the
//// lowering is uniform across frontends because the IR is (high-level §5).
////
//// ## The lowering strategy (structured control → letrec + tail calls)
////
//// The IR is ANF-with-structured-control. Every `Expr` is emitted in **tail position**
//// of the enclosing function under an explicit *continuation* describing what to do
//// with the values it yields:
////
//// - `KReturn` — the values are the function's result (a Core value list). This is the
////   trivial/tail continuation; it is inlined at every site for free.
//// - `KJump(fname)` — apply a materialised join-point `letrec` function with the values
////   (a tail call). Sharing a join point is how multiple exits of a `block`/`if`/`switch`
////   avoid duplicating the code that follows the construct.
//// - `KBind(names, body, next)` — bind the values to `names`, then emit `body` under
////   `next` (this is exactly how `Let` is lowered: `emit(rhs, KBind(names, body, cont))`).
////
//// A multi-exit construct (`If`/`Switch`/`Block`/`Loop`) first **materialises** a
//// non-trivial (`KBind`) continuation into a `letrec` join point so the continuation is
//// emitted once and every exit tail-applies it; a trivial continuation (`KReturn`/
//// `KJump`) is used as-is. Because every `apply` of a join point and every loop back-edge
//// is in tail position, loops run in **constant space** (the verified §5 template) and
//// `return` from any arm always returns from the function.
////
//// ## The binding chokepoint (D3)
////
//// EVERY runtime reference resolves to a concrete `call '<binding.*_module>':'<fn>'(...)`
//// here and nowhere else, against the fixed `twocore@runtime@*` module names carried by
//// the `Binding` (D3a — no ambient authority, no data-driven `apply(Mod, …)`). Numerics
//// route through `binding.num_module`, traps through `trap_module`, the host boundary
//// through `host_module`, metering through `meter_module`, and the resolved `own` stdlib
//// through `stdlib_module`. The `NumOp → rt_num` name table lives here (`num_op_name`)
//// and MUST match `rt_num`'s frozen names. Phase-1 functions are pure: no runtime record
//// is threaded (D3d).
////
//// ## Name legality
////
//// IR variable names need not be Core-legal; the printer's `legalize_var` maps every raw
//// variable token to a legal, injective Core variable (so per-function-unique IR names
//// stay unique). `emit_core` additionally **gensyms** fresh variables (for trapping-op
//// results and metering binders) and fresh `letrec` function atoms (join points and loop
//// heads), each guaranteed not to collide with any name already present in the function.
////
//// ## Scope (Phase 1)
////
//// In: `Values`/`Return`/`Num`/`Convert`/`Let`/`If`/`Switch`/`Block`/`Break`/`Loop`/
//// `Continue`/`CallDirect`/`CallHost`/`Trap`/`Charge`. Out (returns a typed `EmitError`,
//// never a panic): `CallIndirect`, `MemLoad`/`MemStore`, `GlobalGet`/`GlobalSet`,
//// `TermOp`, and the term↔numeric boxing `Convert`s — none are exercised by the Phase-1
//// corpus.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import twocore/backend/core_erlang.{
  type CClause, type CExpr, type CModule, type FName, type FunDef, CApply, CAtom,
  CCall, CCase, CClause, CCons, CFun, CInt, CLet, CLetrec, CNil, CTuple, CValues,
  CVar, FName, FunDef, PAtom, PInt, PTuple, PVar,
}
import twocore/ir.{
  type ConvOp, type Expr, type Function, type IntWidth, type Module, type NumOp,
  type SwitchArm, type TrapReason, type Value, Block, BoxFloat, BoxInt, Break,
  CallDirect, CallHost, CallIndirect, Charge, ConstF32, ConstF64, ConstI32,
  ConstI64, Continue, Convert, FAdd, FDiv, FMax, FMin, FMul, FSub, FW32, FW64,
  GlobalGet, GlobalSet, I32Extend16S, I32Extend8S, I32WrapI64, I64Extend16S,
  I64Extend32S, I64Extend8S, I64ExtendI32S, I64ExtendI32U, IAdd, IAnd, IClz,
  ICtz, IDivS, IDivU, IEq, IEqz, IGeS, IGeU, IGtS, IGtU, ILeS, ILeU, ILtS, ILtU,
  IMul, INe, IOr, IPopcnt, IRemS, IRemU, IRotl, IRotr, IShl, IShrS, IShrU, ISub,
  IXor, If, IndirectCallTypeMismatch, IntDivByZero, IntOverflow, Let, Loop,
  MemLoad, MemStore, MemoryOutOfBounds, Num, ReinterpretFToI, ReinterpretIToF,
  Return, Switch, SwitchArm, TermOp, Trap, TruncSatS, TruncSatU, UnboxFloat,
  UnboxInt, Unreachable, Values, Var, W32, W64,
}
import twocore/runtime/instance.{type Binding}

// ─────────────────────────────── error type (D4) ───────────────────────────────

/// This stage's own error type (D4 — there is no shared `StageError`). `emit_module`
/// returns `Error(EmitError)` — never a panic — for any IR node outside the Phase-1
/// lowering surface or for a structurally inconsistent IR.
///
/// - `UnsupportedNode(node)`: an IR node not lowered in Phase 1 (e.g. `"call_indirect"`,
///   `"mem_load"`, `"global_get"`, `"term_op"`, or a term↔numeric boxing `Convert`).
///   `node` is a stable lowercase tag for the node kind.
/// - `ArityMismatch(expected, got)`: a value-list arity clash — a `Let`/join-point bind
///   whose name count (`expected`) does not equal the number of values produced (`got`).
/// - `UnboundLabel(label)`: a `Break`/`Continue` referencing a label not on the
///   enclosing block/loop stack, or a `Continue` targeting a `Block` (which has no
///   back-edge).
/// - `UnknownFunction(name)`: a `CallDirect` or `ExportFn` naming a function the module
///   does not define.
pub type EmitError {
  UnsupportedNode(node: String)
  ArityMismatch(expected: Int, got: Int)
  UnboundLabel(label: String)
  UnknownFunction(name: String)
}

// ─────────────────────────────── internal state ───────────────────────────────

/// Read-only emission context shared across one module:
/// - `binding`: the runtime `Binding` (the chokepoint table).
/// - `fn_arity`: each defined function's PARAMETER count (the `apply 'f'/n` arity, for
///   resolving `CallDirect`/exports).
/// - `fn_results`: each defined function's RESULT count, needed to unpack a call: a
///   function returning 0/1/many values is realised as a single BEAM value (a dummy / the
///   bare value / a tuple — see `function_return`), so the caller must unpack it back into
///   the right number of values.
type Ctx {
  Ctx(
    binding: Binding,
    fn_arity: Dict(String, Int),
    fn_results: Dict(String, Int),
  )
}

/// A compile-time continuation — what to do with the value list an `Expr` yields.
///
/// - `KReturn`: yield as the function result (a Core value list). Trivial; inlined.
/// - `KJump(target)`: tail-apply a materialised join-point `letrec` function.
/// - `KBind(names, body, next)`: bind the values to `names`, then emit `body` under
///   `next`.
type Cont {
  KReturn
  KJump(target: FName)
  KBind(names: List(String), body: Expr, next: Cont)
}

/// One entry of the compile-time label → continuation stack.
///
/// - `label`: the IR label of the enclosing `Block`/`Loop`.
/// - `break_cont`: the continuation a `Break(label, vs)` (and a `Loop`/`Block`
///   fall-through) resolves to. Always trivial (`KReturn`/`KJump`) — a non-trivial
///   continuation is materialised before the label is pushed.
/// - `continue_target`: `Some(fname)` for a `Loop` (the head to tail-apply on
///   `Continue`); `None` for a `Block` (which has no back-edge).
type LabelEntry {
  LabelEntry(label: String, break_cont: Cont, continue_target: Option(FName))
}

/// Mutable-threaded emission state: a monotonic gensym `counter`, the reserved variable
/// names (`vars`) and reserved function atoms (`fns`) that gensym must avoid, and the
/// scoped label stack (`labels`).
type EmitState {
  EmitState(
    counter: Int,
    vars: Set(String),
    fns: Set(String),
    labels: List(LabelEntry),
  )
}

/// A fresh Core-variable raw name guaranteed distinct from every name already reserved
/// in this function. Returns the name and the advanced state.
fn fresh_var(s: EmitState) -> #(String, EmitState) {
  let cand = "g" <> int.to_string(s.counter)
  let s2 = EmitState(..s, counter: s.counter + 1)
  case set.contains(s.vars, cand) {
    True -> fresh_var(s2)
    False -> #(cand, EmitState(..s2, vars: set.insert(s2.vars, cand)))
  }
}

/// A fresh `letrec` function atom guaranteed distinct from every module function name and
/// previously-generated join-point/loop atom. Returns the name and the advanced state.
fn fresh_fn(s: EmitState) -> #(String, EmitState) {
  let cand = "j" <> int.to_string(s.counter)
  let s2 = EmitState(..s, counter: s.counter + 1)
  case set.contains(s.fns, cand) {
    True -> fresh_fn(s2)
    False -> #(cand, EmitState(..s2, fns: set.insert(s2.fns, cand)))
  }
}

/// Push `entry` for the dynamic extent of the construct that owns the label.
fn push_label(s: EmitState, entry: LabelEntry) -> EmitState {
  EmitState(..s, labels: [entry, ..s.labels])
}

/// Restore the label stack to `labels` (popping a scope) while keeping the monotonic
/// gensym counter and reserved-name sets from `s`.
fn restore_labels(s: EmitState, labels: List(LabelEntry)) -> EmitState {
  EmitState(..s, labels: labels)
}

/// Resolve a label on the enclosing stack, or `Error(UnboundLabel)`.
fn find_label(s: EmitState, label: String) -> Result(LabelEntry, EmitError) {
  case list.find(s.labels, fn(e) { e.label == label }) {
    Ok(e) -> Ok(e)
    Error(_) -> Error(UnboundLabel(label))
  }
}

// ─────────────────────────────── module entry point ───────────────────────────────

/// Lower a shared-IR module to a Core Erlang module AST (unit 03's `CModule`), resolving
/// every runtime reference through `binding` (D3b).
///
/// - `module`: the IR module to lower. Its `functions` become top-level Core defs
///   `'name'/arity = fun (params…) -> <body>`; its `exports` become the Core export list
///   (an `ExportFn` whose `export_name` differs from `fn_name` gets a thin forwarding
///   wrapper, since Core Erlang exports a function by its own name/arity).
/// - `binding`: the build-time runtime binding (the fixed `twocore@runtime@*` module
///   names). Never embedded in or threaded through generated code (D3d).
///
/// Returns `Ok(CModule)` on success. Returns `Error(EmitError)` — never a panic — for any
/// IR node outside the Phase-1 surface (`CallIndirect`, memory/global/term ops, boxing
/// conversions), an unknown `CallDirect`/export target, an unbound `Break`/`Continue`
/// label, or a value-list arity clash. The emitted module name is `module.name` verbatim;
/// `twocore@…` namespacing is the caller's responsibility (overview §5).
pub fn emit_module(
  module: Module,
  binding: Binding,
) -> Result(CModule, EmitError) {
  let fn_arity =
    list.map(module.functions, fn(f) { #(f.name, list.length(f.params)) })
    |> dict.from_list
  let fn_results =
    list.map(module.functions, fn(f) { #(f.name, list.length(f.result)) })
    |> dict.from_list
  let ctx = Ctx(binding: binding, fn_arity: fn_arity, fn_results: fn_results)
  use defs <- result.try(
    list.try_map(module.functions, fn(f) { emit_function(f, ctx) }),
  )
  use #(export_names, wrappers) <- result.try(emit_exports(
    module.exports,
    fn_arity,
  ))
  Ok(core_erlang.CModule(
    name: module.name,
    exports: export_names,
    attributes: [],
    defs: list.append(defs, wrappers),
  ))
}

/// Build the Core export list and any forwarding wrappers from the IR exports.
///
/// For `ExportFn(export_name, fn_name)`: if the two names are equal, export
/// `'fn_name'/arity` directly; otherwise emit a wrapper `'export_name'/arity = fun(A…) ->
/// apply 'fn_name'/arity(A…)` (Core Erlang exports a function by its own name) and export
/// the wrapper. `Error(UnknownFunction)` if `fn_name` is not defined in the module.
fn emit_exports(
  exports: List(ir.ExportDecl),
  fn_arity: Dict(String, Int),
) -> Result(#(List(FName), List(FunDef)), EmitError) {
  list.try_fold(exports, #([], []), fn(acc, exp) {
    let #(names, wrappers) = acc
    let ir.ExportFn(export_name, fn_name) = exp
    case dict.get(fn_arity, fn_name) {
      Error(_) -> Error(UnknownFunction(fn_name))
      Ok(arity) ->
        case export_name == fn_name {
          True -> Ok(#([FName(fn_name, arity), ..names], wrappers))
          False -> {
            let params =
              list.index_map(list.repeat("", arity), fn(_, i) {
                "ea" <> int.to_string(i)
              })
            let body = CApply(FName(fn_name, arity), list.map(params, CVar))
            let wrapper = FunDef(FName(export_name, arity), CFun(params, body))
            Ok(#([FName(export_name, arity), ..names], [wrapper, ..wrappers]))
          }
        }
    }
  })
  |> result.map(fn(acc) {
    let #(names, wrappers) = acc
    #(list.reverse(names), list.reverse(wrappers))
  })
}

/// Lower one IR `Function` to a top-level Core `FunDef`.
///
/// The body is emitted in tail position under `KReturn`. The Core `fun`'s parameters are
/// the IR param names verbatim (the printer legalizes them). Declared `locals` are not
/// pre-bound: in the Phase-1 corpus `locals` is empty and all body bindings come from
/// `Let`/loop params; a frontend that populates `locals` must also bind them.
fn emit_function(f: Function, ctx: Ctx) -> Result(FunDef, EmitError) {
  let reserved_vars = collect_vars(f)
  let reserved_fns = set.from_list(dict.keys(ctx.fn_arity))
  let state0 =
    EmitState(counter: 0, vars: reserved_vars, fns: reserved_fns, labels: [])
  use #(body, _state) <- result.try(emit(f.body, KReturn, state0, ctx))
  let params = list.map(f.params, fn(l) { l.name })
  Ok(FunDef(FName(f.name, list.length(f.params)), CFun(params, body)))
}

// ─────────────────────────────── the core emitter ───────────────────────────────

/// Emit `expr` in tail position under continuation `cont`, threading `state`.
///
/// Returns the Core expression for `expr` (its yielded values disposed of by `cont`) and
/// the advanced state, or an `EmitError`. The non-returning transfers (`Return`/`Trap`/
/// `Break`/`Continue`) ignore `cont` and emit the transfer directly.
fn emit(
  expr: Expr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case expr {
    Values(vs) -> apply_cont(cont, list.map(vs, emit_value), state, ctx)
    Return(vs) -> Ok(#(function_return(list.map(vs, emit_value)), state))
    Num(op, args) -> emit_num(op, args, cont, state, ctx)
    Convert(op, arg) -> emit_convert(op, arg, cont, state, ctx)
    CallDirect(fn_name, args) ->
      emit_call_direct(fn_name, args, cont, state, ctx)
    CallHost(cap, name, args) ->
      emit_call_host(cap, name, args, cont, state, ctx)
    Let(names, rhs, body) -> emit(rhs, KBind(names, body, cont), state, ctx)
    If(cond, result, t, e) -> emit_if(cond, result, t, e, cont, state, ctx)
    Switch(sel, result, arms, default) ->
      emit_switch(sel, result, arms, default, cont, state, ctx)
    Block(label, result, body) ->
      emit_block(label, result, body, cont, state, ctx)
    Loop(label, params, result, body) ->
      emit_loop(label, params, result, body, cont, state, ctx)
    Break(label, vs) -> emit_break(label, vs, state, ctx)
    Continue(label, vs) -> emit_continue(label, vs, state)
    Trap(reason) ->
      Ok(#(raise_trap(ctx, CAtom(trap_reason_atom(reason))), state))
    Charge(cost, body) -> emit_charge(cost, body, cont, state, ctx)
    // Out of Phase-1 scope — typed error, never a panic.
    CallIndirect(..) -> Error(UnsupportedNode("call_indirect"))
    MemLoad(..) -> Error(UnsupportedNode("mem_load"))
    MemStore(..) -> Error(UnsupportedNode("mem_store"))
    GlobalGet(..) -> Error(UnsupportedNode("global_get"))
    GlobalSet(..) -> Error(UnsupportedNode("global_set"))
    TermOp(..) -> Error(UnsupportedNode("term_op"))
  }
}

/// Dispose of the produced `vals` according to `cont`.
///
/// `KReturn` yields them as a value list; `KJump` tail-applies the join point; `KBind`
/// binds them to its names (`ArityMismatch` if the counts differ) and emits its body.
fn apply_cont(
  cont: Cont,
  vals: List(CExpr),
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case cont {
    KReturn -> Ok(#(function_return(vals), state))
    KJump(target) -> Ok(#(CApply(target, vals), state))
    KBind(names, body, next) ->
      case list.length(names) == list.length(vals) {
        False -> Error(ArityMismatch(list.length(names), list.length(vals)))
        True -> {
          use #(body_c, state2) <- result.try(emit(body, next, state, ctx))
          Ok(#(CLet(names, value_list(vals), body_c), state2))
        }
      }
  }
}

/// Dispose a single Core expression `produced` that itself yields a value LIST (a
/// `CallDirect`/`CallHost` to a function returning 0, 1, or many values) according to
/// `cont`.
///
/// A `CallDirect`/`CallHost` is realised as a single BEAM `apply`/`call` whose result is
/// ONE value — but the callee logically returns `r` values, packaged by `function_return`
/// (a dummy for `r==0`, the bare value for `r==1`, an `r`-tuple for `r>=2`). This routine
/// UNPACKS that single value back into `r` Core values and disposes them through `cont`.
///
/// - `KReturn`: the caller's own result is the same `r`-valued thing, already packaged
///   identically — yield `produced` straight through (no unpack/repack).
/// - otherwise: unpack and feed `apply_cont`:
///   - `r==0`: bind+discard the dummy (`let <_> = produced in …`), continue with no values;
///   - `r==1`: continue with the bare value (this matches the legacy single-result shape
///     exactly, so existing `.core` goldens are preserved);
///   - `r>=2`: destructure the result tuple `<{V1,…,Vr}>` and continue with `V1,…,Vr`.
///
/// `r` is the callee's result count (from `ctx.fn_results` for `CallDirect`; `1` for a
/// `CallHost`, whose Phase-1 fates each yield one value or raise). Validation guarantees
/// `r` matches the surrounding binding, so no arity error is raised here.
fn apply_cont_call(
  cont: Cont,
  produced: CExpr,
  r: Int,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case cont {
    KReturn -> Ok(#(produced, state))
    _ ->
      case r {
        0 -> {
          let #(g, state2) = fresh_var(state)
          use #(rest, state3) <- result.try(apply_cont(cont, [], state2, ctx))
          Ok(#(CLet([g], produced, rest), state3))
        }
        1 -> apply_cont(cont, [produced], state, ctx)
        _ -> {
          let #(names, state2) = fresh_n_vars(state, r)
          use #(rest, state3) <- result.try(apply_cont(
            cont,
            list.map(names, CVar),
            state2,
            ctx,
          ))
          let clause =
            CClause([PTuple(list.map(names, PVar))], CAtom("true"), rest)
          Ok(#(CCase(produced, [clause]), state3))
        }
      }
  }
}

/// `n` fresh Core-variable raw names (in order), each distinct from every reserved name,
/// plus the advanced state. Used to destructure a multi-value call result tuple.
fn fresh_n_vars(state: EmitState, n: Int) -> #(List(String), EmitState) {
  case n <= 0 {
    True -> #([], state)
    False -> {
      let #(name, state2) = fresh_var(state)
      let #(rest, state3) = fresh_n_vars(state2, n - 1)
      #([name, ..rest], state3)
    }
  }
}

/// Materialise `cont` into a shared join point if it is non-trivial.
///
/// `arity` is the number of values the multi-exit construct yields. A `KBind` continuation
/// is lowered to a `letrec 'J'/arity = fun(names…) -> <body under next>`; the returned
/// `Cont` becomes `KJump('J')` so every exit tail-applies it once. A trivial continuation
/// (`KReturn`/`KJump`) is returned unchanged with no join point. `ArityMismatch` if the
/// bind's name count differs from `arity`.
fn materialize(
  cont: Cont,
  arity: Int,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(Option(FunDef), Cont, EmitState), EmitError) {
  case cont {
    KReturn -> Ok(#(None, KReturn, state))
    KJump(t) -> Ok(#(None, KJump(t), state))
    KBind(names, body, next) ->
      case list.length(names) == arity {
        False -> Error(ArityMismatch(arity, list.length(names)))
        True -> {
          let #(jname, state2) = fresh_fn(state)
          let fname = FName(jname, arity)
          use #(jbody, state3) <- result.try(emit(body, next, state2, ctx))
          let jdef = FunDef(fname, CFun(names, jbody))
          Ok(#(Some(jdef), KJump(fname), state3))
        }
      }
  }
}

/// Wrap `inner` in a `letrec` for `maybe_def` (the materialised join point), if any.
fn wrap_join(maybe_def: Option(FunDef), inner: CExpr) -> CExpr {
  case maybe_def {
    Some(def) -> CLetrec([def], inner)
    None -> inner
  }
}

// ─────────────────────────────── numeric ops (the chokepoint) ───────────────────────────────

/// Lower a `Num` op through `binding.num_module` (the numeric chokepoint).
///
/// Non-trapping ops emit `call '<num>':'<fn>'(args…)` and pass the single result to
/// `cont`. The four trapping ops (`div`/`rem`, signed and unsigned) return
/// `Result(Int, TrapReason)` = `{ok,X}`/`{error,R}`; they emit the verified
/// `case`-and-`raise` shape, continuing with `X` on `{ok,X}` and raising `R` via
/// `binding.trap_module` on `{error,R}`.
fn emit_num(
  op: NumOp,
  args: List(Value),
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call =
    CCall(
      CAtom(ctx.binding.num_module),
      CAtom(num_op_name(op)),
      list.map(args, emit_value),
    )
  case is_trapping(op) {
    False -> apply_cont(cont, [call], state, ctx)
    True -> {
      // A trapping op yields EXACTLY ONE value (or raises). Reduce it to a single bound
      // variable `rvar` via a `case` whose BOTH clauses yield one value — the unwrapped
      // `{ok,X}` result, or the never-returning `raise` on `{error,E}` — then thread that
      // single value through `cont` normally. Binding once and threading once keeps the
      // two `case` arms arity-consistent (both yield 1) regardless of the surrounding
      // value-list arity: a 0-result function (cont yields `<>`) or a multi-value join
      // point would break a structure that inlined `cont` into only the `ok` arm, because
      // then the `error` arm's lone `raise` value would disagree with the `ok` arm's arity
      // (the Core compiler rejects that as a "return count mismatch").
      let #(xvar, state2) = fresh_var(state)
      let #(evar, state3) = fresh_var(state2)
      let #(rvar, state4) = fresh_var(state3)
      let result_case =
        CCase(call, [
          CClause(
            [PTuple([PAtom("ok"), PVar(xvar)])],
            CAtom("true"),
            CVar(xvar),
          ),
          CClause(
            [PTuple([PAtom("error"), PVar(evar)])],
            CAtom("true"),
            raise_trap(ctx, CVar(evar)),
          ),
        ])
      use #(rest, state5) <- result.try(apply_cont(
        cont,
        [CVar(rvar)],
        state4,
        ctx,
      ))
      Ok(#(CLet([rvar], result_case, rest), state5))
    }
  }
}

/// Lower a `Convert` op. Numeric width/sign/reinterpret/saturating-truncation
/// conversions route through `binding.num_module` (the same chokepoint). The
/// term↔numeric boxing conversions are out of Phase-1 scope → `Error(UnsupportedNode)`.
fn emit_convert(
  op: ConvOp,
  arg: Value,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case conv_op_name(op) {
    Error(node) -> Error(UnsupportedNode(node))
    Ok(fn_name) ->
      apply_cont(
        cont,
        [
          CCall(CAtom(ctx.binding.num_module), CAtom(fn_name), [emit_value(arg)]),
        ],
        state,
        ctx,
      )
  }
}

/// Emit a trap raise: `call '<trap_module>':'raise'(Reason)`. `reason_expr` is the
/// trap-kind atom (for `Trap`) or the error payload var (for a trapping `Num` error arm).
fn raise_trap(ctx: Ctx, reason_expr: CExpr) -> CExpr {
  CCall(CAtom(ctx.binding.trap_module), CAtom("raise"), [reason_expr])
}

// ─────────────────────────────── calls ───────────────────────────────

/// Lower a `CallDirect` to `apply 'fn'/arity(args…)` against a same-module function
/// (a static local name — D3a-safe). `Error(UnknownFunction)` if the target is undefined.
fn emit_call_direct(
  fn_name: String,
  args: List(Value),
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case dict.get(ctx.fn_arity, fn_name) {
    Error(_) -> Error(UnknownFunction(fn_name))
    Ok(arity) -> {
      let r = result.unwrap(dict.get(ctx.fn_results, fn_name), 1)
      apply_cont_call(
        cont,
        CApply(FName(fn_name, arity), list.map(args, emit_value)),
        r,
        state,
        ctx,
      )
    }
  }
}

/// Lower a `CallHost` (the capability boundary, D9). Two fates:
///
/// - a resolved `own`-stdlib triple (`resolve_stdlib`) → a DIRECT
///   `call '<stdlib_module>':'<fn>'(args…)` (a vetted call does not pass through the host);
/// - otherwise (a genuine host import) → the deny-all
///   `call '<host_module>':'call_host'(Cap, Name, [args…])`, which under the Safe profile
///   fails closed.
///
/// SEAM (for unit 11's `ir_lower`, the allowlist enforcer): `resolve_stdlib` here mirrors
/// the pinned own-stdlib mapping. `ir_lower` is the canonical place the resolution +
/// `rt_bif` allowlist is enforced; this table must stay aligned with it. `Cap`/`Name` are
/// emitted as atoms — the deny-all host only echoes them in `{capability_denied, Cap,
/// Name}` and inspects nothing, so this is faithful for the rejection path.
fn emit_call_host(
  capability: String,
  name: String,
  args: List(Value),
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let cargs = list.map(args, emit_value)
  case resolve_stdlib(capability, name) {
    Some(fn_name) ->
      // A vetted `own`-stdlib call yields a single value (Phase-1: `gcd/2`).
      apply_cont_call(
        cont,
        CCall(CAtom(ctx.binding.stdlib_module), CAtom(fn_name), cargs),
        1,
        state,
        ctx,
      )
    None -> {
      // The deny-all host yields a single value or raises (`{capability_denied,…}`).
      let call =
        CCall(CAtom(ctx.binding.host_module), CAtom("call_host"), [
          CAtom(capability),
          CAtom(name),
          core_list(cargs),
        ])
      apply_cont_call(cont, call, 1, state, ctx)
    }
  }
}

/// The resolved `own`-stdlib lookup (the positive fate of `CallHost`). Returns the
/// `rt_stdlib` function name if `(capability, name)` is a vetted stdlib entry.
///
/// Phase-1 pins exactly one triple (state.md): `("std", "gcd")` → `rt_stdlib:gcd/2`.
/// Keep this aligned with unit 11's `ir_lower` + the `rt_bif` allowlist.
fn resolve_stdlib(capability: String, name: String) -> Option(String) {
  case capability, name {
    "std", "gcd" -> Some("gcd")
    _, _ -> None
  }
}

// ─────────────────────────────── structured control ───────────────────────────────

/// Lower `If` to a `case` on the i32 condition. Per the IR contract `cond` is an i32 truth
/// value (`0` = false, non-zero = true), so we match the integer directly — `<0>` selects
/// the else branch, a fresh wildcard selects the then branch — avoiding any external BIF
/// call (keeping the D3a invariant that every `call` targets a runtime module). Both arms
/// are emitted under the (materialised) continuation so each yields the merged result; every
/// `case` clause carries the mandatory `when 'true'` guard.
fn emit_if(
  cond: Value,
  result: List(ir.ValType),
  then_branch: Expr,
  else_branch: Expr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, jcont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    state,
    ctx,
  ))
  use #(then_c, state3) <- result.try(emit(then_branch, jcont, state2, ctx))
  use #(else_c, state4) <- result.try(emit(else_branch, jcont, state3, ctx))
  let #(wild, state5) = fresh_var(state4)
  let case_expr =
    CCase(emit_value(cond), [
      CClause([PInt(0)], CAtom("true"), else_c),
      CClause([PVar(wild)], CAtom("true"), then_c),
    ])
  Ok(#(wrap_join(maybe_def, case_expr), state5))
}

/// Lower `Switch` to a `case` on the integer selector: one `<match>` clause per arm and a
/// trailing wildcard clause for `default`. Every clause carries `when 'true'`; all arms and
/// the default are emitted under the (materialised) continuation.
fn emit_switch(
  selector: Value,
  result: List(ir.ValType),
  arms: List(SwitchArm),
  default: Expr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, jcont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    state,
    ctx,
  ))
  use #(arm_clauses, state3) <- result.try(
    emit_switch_arms(arms, jcont, state2, ctx, []),
  )
  use #(default_c, state4) <- result.try(emit(default, jcont, state3, ctx))
  let #(wild, state5) = fresh_var(state4)
  let clauses =
    list.append(arm_clauses, [CClause([PVar(wild)], CAtom("true"), default_c)])
  Ok(#(wrap_join(maybe_def, CCase(emit_value(selector), clauses)), state5))
}

/// Emit the `Switch` arm clauses, threading state (accumulator in reverse).
fn emit_switch_arms(
  arms: List(SwitchArm),
  jcont: Cont,
  state: EmitState,
  ctx: Ctx,
  acc: List(CClause),
) -> Result(#(List(CClause), EmitState), EmitError) {
  case arms {
    [] -> Ok(#(list.reverse(acc), state))
    [SwitchArm(match, body), ..rest] -> {
      use #(body_c, state2) <- result.try(emit(body, jcont, state, ctx))
      let clause = CClause([PInt(match)], CAtom("true"), body_c)
      emit_switch_arms(rest, jcont, state2, ctx, [clause, ..acc])
    }
  }
}

/// Lower `Block` to a forward continuation. A non-trivial continuation is materialised into
/// a join point; the block body is emitted with both fall-through and `Break(label, …)`
/// resolving to that exit continuation (so the code after the block is emitted once).
fn emit_block(
  label: String,
  result: List(ir.ValType),
  body: Expr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, exit_cont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    state,
    ctx,
  ))
  let state3 = push_label(state2, LabelEntry(label, exit_cont, None))
  use #(body_c, state4) <- result.try(emit(body, exit_cont, state3, ctx))
  let state5 = restore_labels(state4, state2.labels)
  Ok(#(wrap_join(maybe_def, body_c), state5))
}

/// Lower `Loop` to the verified §5 template: `letrec 'L'/arity = fun(params…) -> <body>`
/// applied to the loop-param inits. `Continue(label, vs)` becomes a tail `apply 'L'(vs)`
/// (the back-edge → constant space); fall-through and `Break(label, …)` exit through the
/// (materialised) continuation.
fn emit_loop(
  label: String,
  params: List(ir.LoopParam),
  result: List(ir.ValType),
  body: Expr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let arity = list.length(params)
  use #(maybe_def, exit_cont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    state,
    ctx,
  ))
  let #(lname, state3) = fresh_fn(state2)
  let lfname = FName(lname, arity)
  let state4 = push_label(state3, LabelEntry(label, exit_cont, Some(lfname)))
  use #(body_c, state5) <- result.try(emit(body, exit_cont, state4, ctx))
  let state6 = restore_labels(state5, state3.labels)
  let param_names = list.map(params, fn(p) { p.name })
  let inits = list.map(params, fn(p) { emit_value(p.init) })
  let loop_def = FunDef(lfname, CFun(param_names, body_c))
  let loop_expr = CLetrec([loop_def], CApply(lfname, inits))
  Ok(#(wrap_join(maybe_def, loop_expr), state6))
}

/// Lower `Break(label, vs)`: resolve the label's exit continuation and dispose `vs`
/// through it. `Error(UnboundLabel)` if the label is not in scope.
fn emit_break(
  label: String,
  vs: List(Value),
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use entry <- result.try(find_label(state, label))
  apply_cont(entry.break_cont, list.map(vs, emit_value), state, ctx)
}

/// Lower `Continue(label, vs)`: tail-apply the loop head `apply 'L'(vs)`.
/// `Error(UnboundLabel)` if the label is not in scope or names a `Block` (no back-edge).
fn emit_continue(
  label: String,
  vs: List(Value),
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  use entry <- result.try(find_label(state, label))
  case entry.continue_target {
    Some(lfname) -> Ok(#(CApply(lfname, list.map(vs, emit_value)), state))
    None -> Error(UnboundLabel(label))
  }
}

/// Lower `Charge(cost, body)` to the metering seam (D9): `let _ =
/// call '<meter_module>':'charge'(Cost) in <body>`. The seam must exist; the impl being a
/// fuel counter is unit 09's job.
fn emit_charge(
  cost: Int,
  body: Expr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(wild, state2) = fresh_var(state)
  use #(body_c, state3) <- result.try(emit(body, cont, state2, ctx))
  let charge_call =
    CCall(CAtom(ctx.binding.meter_module), CAtom("charge"), [CInt(cost)])
  Ok(#(CLet([wild], charge_call, body_c), state3))
}

// ─────────────────────────────── values ───────────────────────────────

/// Lower an atomic IR `Value` to a Core expression. Variables become `CVar` (raw name —
/// the printer legalizes). Every constant is its RAW BIT PATTERN as a `CInt` (integers as
/// the unsigned bit pattern; floats as their IEEE-754 bits per D5 — never a Core float).
fn emit_value(v: Value) -> CExpr {
  case v {
    Var(name) -> CVar(name)
    ConstI32(bits) -> CInt(bits)
    ConstI64(bits) -> CInt(bits)
    ConstF32(bits) -> CInt(bits)
    ConstF64(bits) -> CInt(bits)
  }
}

/// A Core value list: a single value is itself; zero or many become `<…>` (`CValues`).
/// Used for *internal* value-list positions (the RHS of a `let <names…> = … in …` and the
/// arguments of a join-point `apply`), where Core Erlang permits an arbitrary-arity value
/// list. NOT used at a function/join-point return boundary — see `function_return`.
fn value_list(exprs: List(CExpr)) -> CExpr {
  case exprs {
    [single] -> single
    _ -> CValues(exprs)
  }
}

/// Package a function/join-point's result value list into the SINGLE value a BEAM function
/// must return (Core Erlang rejects a top-level body that yields a value list of arity ≠ 1
/// as a "return count mismatch"):
///
/// - 0 results (a `void`/zero-result WASM function) → the canonical unit atom `'ok'`. The
///   conformance driver ignores a zero-result return, so the concrete value is immaterial;
///   what matters is that exactly one value is produced so the function compiles (and any
///   trap inside it still raises).
/// - 1 result → the bare value (the common case; unchanged).
/// - N≥2 results (multi-value) → an N-tuple `{V1,…,Vn}`. The matching `apply_cont_call`
///   destructures this tuple at the call site, so the multi-value convention round-trips.
///   Direct multi-value *invocation* remains out of Phase-1 scope (the driver skips it);
///   this only makes multi-value functions and their callers compile and compute correctly.
fn function_return(exprs: List(CExpr)) -> CExpr {
  case exprs {
    [] -> CAtom("ok")
    [single] -> single
    _ -> CTuple(exprs)
  }
}

/// Build a proper Core list `[E1, E2, …]` (`CCons` chain ending in `CNil`).
fn core_list(exprs: List(CExpr)) -> CExpr {
  list.fold_right(exprs, CNil, fn(acc, e) { CCons(e, acc) })
}

// ─────────────────────────────── the NumOp → rt_num name table ───────────────────────────────

/// Map a `NumOp` to its `rt_num` function name (the chokepoint table; MUST match the
/// frozen `rt_num` signatures). Names are `i{32|64}_<op>` / `f{32|64}_<op>` where `<op>`
/// is the snake_case suffix (`add`, `div_s`, `shr_u`, `lt_u`, …). Total — every `NumOp`
/// constructor is mapped.
pub fn num_op_name(op: NumOp) -> String {
  case op {
    IAdd(w) -> iw(w) <> "_add"
    ISub(w) -> iw(w) <> "_sub"
    IMul(w) -> iw(w) <> "_mul"
    IDivS(w) -> iw(w) <> "_div_s"
    IDivU(w) -> iw(w) <> "_div_u"
    IRemS(w) -> iw(w) <> "_rem_s"
    IRemU(w) -> iw(w) <> "_rem_u"
    IAnd(w) -> iw(w) <> "_and"
    IOr(w) -> iw(w) <> "_or"
    IXor(w) -> iw(w) <> "_xor"
    IShl(w) -> iw(w) <> "_shl"
    IShrS(w) -> iw(w) <> "_shr_s"
    IShrU(w) -> iw(w) <> "_shr_u"
    IRotl(w) -> iw(w) <> "_rotl"
    IRotr(w) -> iw(w) <> "_rotr"
    IClz(w) -> iw(w) <> "_clz"
    ICtz(w) -> iw(w) <> "_ctz"
    IPopcnt(w) -> iw(w) <> "_popcnt"
    IEqz(w) -> iw(w) <> "_eqz"
    IEq(w) -> iw(w) <> "_eq"
    INe(w) -> iw(w) <> "_ne"
    ILtS(w) -> iw(w) <> "_lt_s"
    ILtU(w) -> iw(w) <> "_lt_u"
    IGtS(w) -> iw(w) <> "_gt_s"
    IGtU(w) -> iw(w) <> "_gt_u"
    ILeS(w) -> iw(w) <> "_le_s"
    ILeU(w) -> iw(w) <> "_le_u"
    IGeS(w) -> iw(w) <> "_ge_s"
    IGeU(w) -> iw(w) <> "_ge_u"
    FAdd(f) -> fw(f) <> "_add"
    FSub(f) -> fw(f) <> "_sub"
    FMul(f) -> fw(f) <> "_mul"
    FDiv(f) -> fw(f) <> "_div"
    FMin(f) -> fw(f) <> "_min"
    FMax(f) -> fw(f) <> "_max"
  }
}

/// `True` for the four trapping ops (`div`/`rem`, signed/unsigned) — those return
/// `Result(Int, TrapReason)` and need the `case`-and-`raise` lowering. All other ops
/// return a bare `Int`.
fn is_trapping(op: NumOp) -> Bool {
  case op {
    IDivS(_) | IDivU(_) | IRemS(_) | IRemU(_) -> True
    _ -> False
  }
}

/// Map a `ConvOp` to its `rt_num` function name, or `Error(node_tag)` for the term↔numeric
/// boxing conversions (out of Phase-1 scope).
fn conv_op_name(op: ConvOp) -> Result(String, String) {
  case op {
    I32WrapI64 -> Ok("i32_wrap_i64")
    I64ExtendI32S -> Ok("i64_extend_i32_s")
    I64ExtendI32U -> Ok("i64_extend_i32_u")
    I32Extend8S -> Ok("i32_extend8_s")
    I32Extend16S -> Ok("i32_extend16_s")
    I64Extend8S -> Ok("i64_extend8_s")
    I64Extend16S -> Ok("i64_extend16_s")
    I64Extend32S -> Ok("i64_extend32_s")
    TruncSatS(from, to) -> Ok(iw(to) <> "_trunc_sat_f" <> fwn(from) <> "_s")
    TruncSatU(from, to) -> Ok(iw(to) <> "_trunc_sat_f" <> fwn(from) <> "_u")
    ReinterpretFToI(FW32) -> Ok("i32_reinterpret_f32")
    ReinterpretFToI(FW64) -> Ok("i64_reinterpret_f64")
    ReinterpretIToF(W32) -> Ok("f32_reinterpret_i32")
    ReinterpretIToF(W64) -> Ok("f64_reinterpret_i64")
    BoxInt(_) -> Error("box_int")
    UnboxInt(_) -> Error("unbox_int")
    BoxFloat(_) -> Error("box_float")
    UnboxFloat(_) -> Error("unbox_float")
  }
}

/// The integer-op module/name prefix for a width (`"i32"` / `"i64"`).
fn iw(w: IntWidth) -> String {
  case w {
    W32 -> "i32"
    W64 -> "i64"
  }
}

/// The float-op module/name prefix for a width (`"f32"` / `"f64"`).
fn fw(f: ir.FloatWidth) -> String {
  case f {
    FW32 -> "f32"
    FW64 -> "f64"
  }
}

/// The bare width number of a float width (`"32"` / `"64"`), for composing trunc_sat names.
fn fwn(f: ir.FloatWidth) -> String {
  case f {
    FW32 -> "32"
    FW64 -> "64"
  }
}

// ─────────────────────────────── trap-atom wrapper (fact 2) ───────────────────────────────

/// The Erlang atom a `TrapReason` becomes — exactly how Gleam compiles its 0-field
/// constructor (PascalCase → snake_case), e.g. `IntDivByZero` → `"int_div_by_zero"`.
/// Generated code passes this atom to `rt_trap:raise/1`. Total — covers every constructor.
pub fn trap_reason_atom(reason: TrapReason) -> String {
  pascal_to_snake(trap_ctor_name(reason))
}

/// The PascalCase source spelling of a `TrapReason` constructor (the input to
/// `pascal_to_snake`). Kept explicit because Gleam has no constructor reflection.
fn trap_ctor_name(reason: TrapReason) -> String {
  case reason {
    IntDivByZero -> "IntDivByZero"
    IntOverflow -> "IntOverflow"
    Unreachable -> "Unreachable"
    IndirectCallTypeMismatch -> "IndirectCallTypeMismatch"
    MemoryOutOfBounds -> "MemoryOutOfBounds"
  }
}

/// Convert a PascalCase identifier to snake_case — the transformation Gleam's compiler
/// applies to a 0-field constructor to derive its runtime atom (verified fact 2). Each
/// uppercase letter after the first is prefixed with `_`, then the whole string is
/// lowercased: `"IntDivByZero"` → `"int_div_by_zero"`. Total; never panics.
pub fn pascal_to_snake(name: String) -> String {
  string.to_utf_codepoints(name)
  |> list.index_map(fn(cp, i) {
    let c = string.utf_codepoint_to_int(cp)
    let s = string.from_utf_codepoints([cp])
    case i > 0 && c >= 65 && c <= 90 {
      True -> "_" <> s
      False -> s
    }
  })
  |> string.concat
  |> string.lowercase
}

// ─────────────────────────────── gensym reservation scan ───────────────────────────────

/// Collect every variable name present in `f` (params, locals, `Let`/loop binders, and all
/// `Value` references) so gensym can avoid colliding with any of them. Over-approximating
/// is safe; the set is only used to keep generated variable tokens unique.
fn collect_vars(f: Function) -> Set(String) {
  let base =
    list.fold(f.params, set.new(), fn(acc, l) { set.insert(acc, l.name) })
  let base = list.fold(f.locals, base, fn(acc, l) { set.insert(acc, l.name) })
  collect_expr(f.body, base)
}

/// Accumulate variable names appearing in `expr` into `acc`.
fn collect_expr(expr: Expr, acc: Set(String)) -> Set(String) {
  case expr {
    Values(vs) -> collect_values(vs, acc)
    Return(vs) -> collect_values(vs, acc)
    Num(_, args) -> collect_values(args, acc)
    Convert(_, arg) -> collect_value(arg, acc)
    TermOp(_, args) -> collect_values(args, acc)
    MemLoad(_, addr, _) -> collect_value(addr, acc)
    MemStore(_, addr, value, _) ->
      collect_value(value, collect_value(addr, acc))
    GlobalGet(_) -> acc
    GlobalSet(_, value) -> collect_value(value, acc)
    CallDirect(_, args) -> collect_values(args, acc)
    CallIndirect(_, index, _, args) ->
      collect_values(args, collect_value(index, acc))
    CallHost(_, _, args) -> collect_values(args, acc)
    Let(names, rhs, body) -> {
      let acc = list.fold(names, acc, set.insert)
      collect_expr(body, collect_expr(rhs, acc))
    }
    If(cond, _, t, e) ->
      collect_expr(e, collect_expr(t, collect_value(cond, acc)))
    Switch(sel, _, arms, default) -> {
      let acc = collect_value(sel, acc)
      let acc =
        list.fold(arms, acc, fn(a, arm) {
          let SwitchArm(_, body) = arm
          collect_expr(body, a)
        })
      collect_expr(default, acc)
    }
    Block(_, _, body) -> collect_expr(body, acc)
    Loop(_, params, _, body) -> {
      let acc =
        list.fold(params, acc, fn(a, p) {
          collect_value(p.init, set.insert(a, p.name))
        })
      collect_expr(body, acc)
    }
    Break(_, vs) -> collect_values(vs, acc)
    Continue(_, vs) -> collect_values(vs, acc)
    Trap(_) -> acc
    Charge(_, body) -> collect_expr(body, acc)
  }
}

/// Accumulate the name of `value` if it is a `Var`.
fn collect_value(value: Value, acc: Set(String)) -> Set(String) {
  case value {
    Var(name) -> set.insert(acc, name)
    _ -> acc
  }
}

/// Accumulate every `Var` name among `values`.
fn collect_values(values: List(Value), acc: Set(String)) -> Set(String) {
  list.fold(values, acc, fn(a, v) { collect_value(v, a) })
}
