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
//// ## Scope (Phase 2)
////
//// In: the Phase-1 surface (`Values`/`Return`/`Num`/`Convert`/`Let`/`If`/`Switch`/`Block`/
//// `Break`/`Loop`/`Continue`/`CallDirect`/`CallHost`/`Trap`/`Charge`) PLUS the stateful ops
//// — `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/`GlobalGet`/`GlobalSet`/`CallIndirect` — and
//// the new float `NumOp`s (`FAbs`…`FGe`/`FCopysign`) and `ConvOp`s (trapping `TruncS`/`TruncU`,
//// total `ConvertS`/`ConvertU`/`F32DemoteF64`/`F64PromoteF32`). All stateful ops route through
//// the ONE state-access seam (`seam_call`) — a direct `call '<binding.X_module>':'op'(...)`
//// for the tier-O cell strategy, no ambient authority (E1/D3a). The backend also emits the
//// generated `instantiate/0` entry (E5) that seeds the per-instance cell and runs the active
//// element/data segments + start. Out (returns a typed `EmitError`, never a panic): `TermOp`
//// and the four term↔numeric boxing `Convert`s (still Phase-3 deferrals).
////
//// ## Phase 3 — posture-agnostic BODIES, seeded `instantiate/0` (F4/F6/F7)
////
//// For every NON-instantiate function body, `emit_module` reads ONLY the `binding.*_module`
//// names (+ `safe_max_pages`); it reads NONE of the policy fields
//// (`opt_level`/`meter`/`bif_gate`/`stdlib`/`host_policy`/`fuel_budget`). Because
//// `profiles.unsafe()` keeps the SAME `*_module` names as `safe()`, those bodies are
//// structurally identical under both profiles for the same IR (Safe and Unsafe are distinct
//// B3 builds; the instance is the unit of policy). The optimizer runs BEFORE emit (F1) and the
//// `Charge`-skip lives in `ir_lower` (F5) — so a metered body's Safe/Unsafe `.core` differs
//// only by charge, never by anything emit_core decides. The ONE documented exception is the
//// synthesized `instantiate/0`, which bakes the per-instance seeds:
//// `rt_meter:seed_fuel(binding.fuel_budget)` FIRST when `meter == MeterFuel`, and ALWAYS
//// `rt_host:seed_policy(binding.host_policy)`. Do NOT branch any non-instantiate body on a
//// policy field: that would break the F5 zero-overhead differential.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import twocore/backend/core_erlang.{
  type CBitSeg, type CClause, type CExpr, type CModule, type CPat, type FName,
  type FunDef, CApply, CAtom, CBinary, CBitSeg, CCall, CCase, CClause, CCons,
  CFun, CInt, CLet, CLetrec, CNil, CTuple, CValues, CVar, FName, FunDef, PAtom,
  PCons, PInt, PNil, PTuple, PVar,
}
import twocore/ir.{
  type ConvOp, type Expr, type FuncType, type Function, type IntWidth,
  type Module, type NumOp, type SwitchArm, type TrapReason, type ValType,
  type Value, Block, BoxFloat, BoxInt, Break, CallDirect, CallHost, CallIndirect,
  Charge, ConstF32, ConstF64, ConstI32, ConstI64, Continue, Convert, ConvertS,
  ConvertU, F32DemoteF64, F64PromoteF32, FAbs, FAdd, FCeil, FCopysign, FDiv, FEq,
  FFloor, FGe, FGt, FLe, FLt, FMax, FMin, FMul, FNe, FNearest, FNeg, FSqrt, FSub,
  FTrunc, FW32, FW64, FuelExhausted, FuncType, GlobalGet, GlobalSet,
  I32Extend16S, I32Extend8S, I32WrapI64, I64Extend16S, I64Extend32S, I64Extend8S,
  I64ExtendI32S, I64ExtendI32U, IAdd, IAnd, IClz, ICtz, IDivS, IDivU, IEq, IEqz,
  IGeS, IGeU, IGtS, IGtU, ILeS, ILeU, ILtS, ILtU, IMul, INe, IOr, IPopcnt, IRemS,
  IRemU, IRotl, IRotr, IShl, IShrS, IShrU, ISub, IXor, If,
  IndirectCallTypeMismatch, IntDivByZero, IntOverflow,
  InvalidConversionToInteger, Let, Loop, MemGrow, MemLoad, MemSize, MemStore,
  MemoryOutOfBounds, Num, ReinterpretFToI, ReinterpretIToF, Return, Switch,
  SwitchArm, TF32, TF64, TI32, TI64, TTerm, TableOutOfBounds, TermOp, Trap,
  TruncS, TruncSatS, TruncSatU, TruncU, UnboxFloat, UnboxInt, UndefinedElement,
  UninitializedElement, Unreachable, Values, Var, W32, W64,
}
import twocore/runtime/instance.{
  type Binding, type HostPolicy, HostDenyAll, HostOpen, HostWhitelist, MeterFuel,
  MeterOff, Threaded,
}

// ─────────────────────────────── error type (D4) ───────────────────────────────

/// This stage's own error type (D4 — there is no shared `StageError`). `emit_module`
/// returns `Error(EmitError)` — never a panic — for any IR node outside the lowering
/// surface or for a structurally inconsistent IR.
///
/// - `UnsupportedNode(node)`: an IR node not lowered (Phase-2 leaves only `"term_op"`
///   and the four term↔numeric boxing `Convert`s — `"box_int"`/`"unbox_int"`/
///   `"box_float"`/`"unbox_float"` — out of scope). `node` is a stable lowercase tag for
///   the node kind. The Phase-2 stateful ops (memory/global/table/size/grow) and the
///   trapping/total `Convert`s are now lowered through the state-access seam, so they no
///   longer appear here.
/// - `ArityMismatch(expected, got)`: a value-list arity clash — a `Let`/join-point bind
///   whose name count (`expected`) does not equal the number of values produced (`got`).
/// - `UnboundLabel(label)`: a `Break`/`Continue` referencing a label not on the
///   enclosing block/loop stack, or a `Continue` targeting a `Block` (which has no
///   back-edge).
/// - `UnknownFunction(name)`: a `CallDirect`, `ExportFn`, `ElementSegment` func, or
///   `start` naming a function the module does not define.
/// - `NonConstInit(detail)`: a `GlobalDecl.init` / data-or-element-segment `offset`
///   expression that is not a Phase-2 constant literal (`t.const` → `Values([Const])`),
///   so the `instantiate/0` entry cannot constant-fold it to a bit pattern. `detail` is a
///   human-readable reason. (Validation upstream already enforces the const-expr rule;
///   this is the fail-closed backend defence — never a panic, never arbitrary emitted
///   code in the seed decl.)
pub type EmitError {
  UnsupportedNode(node: String)
  ArityMismatch(expected: Int, got: Int)
  UnboundLabel(label: String)
  UnknownFunction(name: String)
  NonConstInit(detail: String)
}

// ─────────────────────────────── internal state ───────────────────────────────

/// Read-only emission context shared across one module:
/// - `binding`: the runtime `Binding` (the chokepoint table).
/// - `fn_arity`: each defined function's PARAMETER count (the `apply 'f'/n` arity, for
///   resolving `CallDirect`/exports). NOTE: this is the Phase-1 arity (`n`); a
///   state-reaching function under `Threaded` is emitted and applied at `n+1` (the leading
///   `InstanceState`), so the seam adds `+1` at the call/export site (§B).
/// - `fn_results`: each defined function's RESULT count, needed to unpack a call: a
///   function returning 0/1/many values is realised as a single BEAM value (a dummy / the
///   bare value / a tuple — see `function_return`), so the caller must unpack it back into
///   the right number of values.
/// - `fn_sig`: each defined function's `FuncType` (for the `call_indirect` element type tag).
/// - `fn_state_reaching`: under `state_strategy: Threaded`, the transitive-closure set of
///   functions that touch instance state (§A.3). A function in this set is emitted at
///   arity `n+1`, threads the `InstanceState` record as its leading parameter, and returns
///   `{ResultPackage, St'}`. Computed once in `emit_module`; unused (but harmless) under
///   `Cell`, where every function keeps its Phase-1 shape.
type Ctx {
  Ctx(
    binding: Binding,
    fn_arity: Dict(String, Int),
    fn_results: Dict(String, Int),
    fn_sig: Dict(String, FuncType),
    fn_state_reaching: Set(String),
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

/// The state-threading channel carried alongside `cont` under `state_strategy: Threaded`
/// (keystone §A.2). It is *environment*, not accumulator: it flows down, is REBOUND after
/// each mutating op, and BRANCHES (each `if` arm / loop iteration has its own live record),
/// so it is a parameter, never stored in `EmitState`.
///
/// - `NoState`: the `Cell` strategy, OR a PURE function under `Threaded` — emit today's
///   code. No record is threaded; functions keep their Phase-1 arity; `KReturn` yields the
///   bare `function_return` package.
/// - `Threading(cur)`: `cur` is the raw Core-variable name currently holding the live
///   `InstanceState`. Reads pass `cur`; mutators REBIND a fresh var and continue under
///   `Threading(fresh)`; `KReturn` pairs the package with `cur` into `{Package, cur}`; a
///   `KJump`/loop back-edge PREPENDS `cur` to the value list.
type StateChan {
  NoState
  Threading(cur: String)
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
  let fn_sig =
    list.map(module.functions, fn(f) { #(f.name, ir.signature(f)) })
    |> dict.from_list
  // The state-reaching call-graph closure (§A.3) — computed ONCE, keyed on only under
  // `Threaded`. Under `Cell` it is inert (every function keeps its Phase-1 shape).
  let fn_state_reaching = state_reaching_closure(module.functions)
  let ctx =
    Ctx(
      binding: binding,
      fn_arity: fn_arity,
      fn_results: fn_results,
      fn_sig: fn_sig,
      fn_state_reaching: fn_state_reaching,
    )
  use defs <- result.try(
    list.try_map(module.functions, fn(f) { emit_function(f, ctx) }),
  )
  use #(export_names, wrappers) <- result.try(emit_exports(module.exports, ctx))
  // The generated instantiation entry (E5) — seeds the fresh per-instance cell and runs
  // the active element/data segments + start in WASM spec order. Always emitted and
  // exported so the harness (unit 11) can call `instantiate/0` in the instance process.
  use inst_def <- result.try(emit_instantiate(module, ctx))
  Ok(core_erlang.CModule(
    name: module.name,
    exports: list.append(export_names, [FName("instantiate", 0)]),
    attributes: [],
    defs: list.append(list.append(defs, wrappers), [inst_def]),
  ))
}

/// Build the Core export list and any forwarding wrappers from the IR exports.
///
/// **Under `Cell`** (byte-identical to Phase 2/3): for `ExportFn(export_name, fn_name)`, if
/// the two names are equal export `'fn_name'/arity` directly; otherwise emit a forwarding
/// wrapper `'export_name'/arity = fun(A…) -> apply 'fn_name'/arity(A…)` (Core Erlang exports
/// a function by its own name/arity).
///
/// **Under `Threaded`** the export boundary is made UNIFORM (§B.4) so unit 08's run-ABI can
/// always pass the `InstanceState` leading and always receive `{Package, St'}` — every export
/// presents at arity `n+1`. For `ExportFn(export_name, fn_name)`:
/// - `fn_name` STATE-REACHING and `export_name == fn_name` → export the internal
///   `'fn_name'/(n+1)` DIRECTLY (no wrapper). `emit_function` already emitted it with exactly
///   the run-ABI shape `fun(St, A…) -> {Package, St'}`; synthesizing a same-name/arity wrapper
///   would emit a DUPLICATE `FunDef` (invalid Core) that also self-applies (infinite
///   recursion). This mirrors the `Cell` name-equality check and is the common case
///   (`ExportFn(f, f)`).
/// - `fn_name` STATE-REACHING and `export_name != fn_name` → forwarding wrapper
///   `'export_name'/(n+1) = fun(St, A…) -> apply 'fn_name'/(n+1)(St, A…)` (already
///   `{Package, St'}`). A distinct name cannot collide with the internal `'fn_name'/(n+1)`.
/// - `fn_name` PURE (either name relation) → adapting wrapper
///   `'export_name'/(n+1) = fun(St, A…) -> {apply 'fn_name'/n(A…), St}` — threads `St`
///   straight through. Even when `export_name == fn_name`, the DISTINCT ARITY (`n+1` vs the
///   internal `'fn_name'/n`) keeps them apart, so no collision.
///
/// `Error(UnknownFunction)` if `fn_name` is not defined in the module.
fn emit_exports(
  exports: List(ir.ExportDecl),
  ctx: Ctx,
) -> Result(#(List(FName), List(FunDef)), EmitError) {
  list.try_fold(exports, #([], []), fn(acc, exp) {
    let #(names, wrappers) = acc
    // Only FUNCTION exports lower here (the Phase-1..4 surface, byte-identical). Exported state
    // (global/table/memory — H4) is P5-06/09's; it never appears in the existing corpus, so a
    // typed error keeps the tree green without moving conformance.
    use #(export_name, fn_name) <- result.try(case exp {
      ir.ExportFn(export_name, fn_name) -> Ok(#(export_name, fn_name))
      ir.ExportGlobal(..) -> Error(UnsupportedNode("export_global"))
      ir.ExportTable(..) -> Error(UnsupportedNode("export_table"))
      ir.ExportMemory(..) -> Error(UnsupportedNode("export_memory"))
    })
    case dict.get(ctx.fn_arity, fn_name) {
      Error(_) -> Error(UnknownFunction(fn_name))
      Ok(arity) ->
        case is_threaded(ctx) {
          False ->
            // ── Cell: unchanged (direct export when names match, else a bare forwarder). ──
            case export_name == fn_name {
              True -> Ok(#([FName(fn_name, arity), ..names], wrappers))
              False -> {
                let params = wrapper_arg_params(arity)
                let body = CApply(FName(fn_name, arity), list.map(params, CVar))
                let wrapper =
                  FunDef(FName(export_name, arity), CFun(params, body))
                Ok(
                  #([FName(export_name, arity), ..names], [wrapper, ..wrappers]),
                )
              }
            }
          True ->
            case set.contains(ctx.fn_state_reaching, fn_name) {
              // A state-reaching def already IS the `n+1` run-ABI export.
              True ->
                case export_name == fn_name {
                  // Export it directly — NO second def (the P3 collision fix).
                  True -> Ok(#([FName(fn_name, arity + 1), ..names], wrappers))
                  // A distinctly-named forwarder to the internal `n+1` def.
                  False -> {
                    let params = wrapper_arg_params(arity)
                    let body =
                      CApply(FName(fn_name, arity + 1), [
                        CVar(wrapper_state_param),
                        ..list.map(params, CVar)
                      ])
                    let wrapper =
                      FunDef(
                        FName(export_name, arity + 1),
                        CFun([wrapper_state_param, ..params], body),
                      )
                    Ok(
                      #([FName(export_name, arity + 1), ..names], [
                        wrapper,
                        ..wrappers
                      ]),
                    )
                  }
                }
              // A pure def gets a thin `n+1` adapter returning `{apply 'g'/n(A…), St}`.
              False -> {
                let params = wrapper_arg_params(arity)
                let applied =
                  CApply(FName(fn_name, arity), list.map(params, CVar))
                let body = CTuple([applied, CVar(wrapper_state_param)])
                let wrapper =
                  FunDef(
                    FName(export_name, arity + 1),
                    CFun([wrapper_state_param, ..params], body),
                  )
                Ok(
                  #([FName(export_name, arity + 1), ..names], [
                    wrapper,
                    ..wrappers
                  ]),
                )
              }
            }
        }
    }
  })
  |> result.map(fn(acc) {
    let #(names, wrappers) = acc
    #(list.reverse(names), list.reverse(wrappers))
  })
}

/// The `arity` positional argument-parameter names for a synthesized export wrapper
/// (`ea0`, `ea1`, …). Wrapper-local, so they only need to be internally distinct + Core-legal.
fn wrapper_arg_params(arity: Int) -> List(String) {
  list.index_map(list.repeat("", arity), fn(_, i) { "ea" <> int.to_string(i) })
}

/// The leading `InstanceState` parameter name of a synthesized THREADED export wrapper.
/// Distinct from every `wrapper_arg_params` name (`ea…`), so no wrapper-local collision.
const wrapper_state_param = "est"

/// Lower one IR `Function` to a top-level Core `FunDef`.
///
/// The body is emitted in tail position under `KReturn`. The Core `fun`'s parameters are
/// the IR param names verbatim (the printer legalizes them). Declared `locals` are not
/// pre-bound: in the Phase-1 corpus `locals` is empty and all body bindings come from
/// `Let`/loop params; a frontend that populates `locals` must also bind them.
///
/// Under `state_strategy: Threaded`, a STATE-REACHING function (`ctx.fn_state_reaching`) is
/// emitted as `'f'/(n+1) = fun (St, params…) -> {ResultPackage, St'}` — the `InstanceState`
/// record threaded as the LEADING parameter and paired with the outgoing record on return
/// (§B.1). A PURE function (and every function under `Cell`) keeps its Phase-1 `'f'/n` shape
/// (channel `NoState`), so pure numeric leaves pay nothing.
fn emit_function(f: Function, ctx: Ctx) -> Result(FunDef, EmitError) {
  let reserved_vars = collect_vars(f)
  let reserved_fns = set.from_list(dict.keys(ctx.fn_arity))
  let state0 =
    EmitState(counter: 0, vars: reserved_vars, fns: reserved_fns, labels: [])
  case is_threaded(ctx) && set.contains(ctx.fn_state_reaching, f.name) {
    True -> {
      let #(st0, state1) = fresh_var(state0)
      use #(body, _state) <- result.try(emit(
        f.body,
        KReturn,
        Threading(st0),
        state1,
        ctx,
      ))
      let params = [st0, ..list.map(f.params, fn(l) { l.name })]
      Ok(FunDef(FName(f.name, list.length(f.params) + 1), CFun(params, body)))
    }
    False -> {
      use #(body, _state) <- result.try(emit(
        f.body,
        KReturn,
        NoState,
        state0,
        ctx,
      ))
      let params = list.map(f.params, fn(l) { l.name })
      Ok(FunDef(FName(f.name, list.length(f.params)), CFun(params, body)))
    }
  }
}

/// `True` when the build threads the `InstanceState` record (`state_strategy: Threaded`),
/// `False` for the `Cell` (pdict) strategy — the ONE codegen-shape switch (§A.1).
fn is_threaded(ctx: Ctx) -> Bool {
  ctx.binding.state_strategy == Threaded
}

// ─────────────────────────── the state-reaching call-graph closure (§A.3) ───────────────────────────

/// Compute the set of STATE-REACHING functions: the transitive `CallDirect` closure of the
/// functions whose body contains a stateful op (§A.3). A function is state-reaching iff it
/// (1) contains any of the seven stateful nodes — `MemLoad`/`MemStore`/`MemSize`/`MemGrow`/
/// `GlobalGet`/`GlobalSet`/`CallIndirect` (reads count, since they need the record to read
/// FROM) — or (2) transitively `CallDirect`s a state-reaching function. Computing it as a
/// closure (not just "direct") is the correctness crux of uniform threading: a caller of a
/// memory-touching helper must thread the record even with no stateful node of its own.
///
/// `CallHost`/`Charge` are NOT seeds (the host boundary + fuel counter never touch the
/// record); a `CallIndirect` TARGET is reached via the table (not a `CallDirect` edge), so a
/// pure table target stays pure and only the closure adapter absorbs the ABI (§C). Under
/// `Cell` the result is unused.
fn state_reaching_closure(functions: List(Function)) -> Set(String) {
  let seeds =
    list.filter_map(functions, fn(f) {
      case expr_touches_state(f.body) {
        True -> Ok(f.name)
        False -> Error(Nil)
      }
    })
    |> set.from_list
  let edges =
    list.map(functions, fn(f) { #(f.name, direct_callees(f.body, set.new())) })
    |> dict.from_list
  reaching_fixpoint(functions, edges, seeds)
}

/// The monotone fixpoint over the `CallDirect` edge graph: add any function whose callee set
/// intersects the current state-reaching set, until no function is added. Terminates because
/// the set only grows and is bounded by the (finite) function count.
fn reaching_fixpoint(
  functions: List(Function),
  edges: Dict(String, Set(String)),
  current: Set(String),
) -> Set(String) {
  let next =
    list.fold(functions, current, fn(acc, f) {
      case set.contains(acc, f.name) {
        True -> acc
        False -> {
          let callees = result.unwrap(dict.get(edges, f.name), set.new())
          case any_member(callees, acc) {
            True -> set.insert(acc, f.name)
            False -> acc
          }
        }
      }
    })
  case set.size(next) == set.size(current) {
    True -> current
    False -> reaching_fixpoint(functions, edges, next)
  }
}

/// `True` iff any element of `xs` is a member of `ys` (a non-empty set intersection).
fn any_member(xs: Set(String), ys: Set(String)) -> Bool {
  set.fold(xs, False, fn(found, x) { found || set.contains(ys, x) })
}

/// `True` iff `expr` (recursively) contains one of the seven stateful nodes — the seeding
/// condition (§A.3). `CallDirect`/`CallHost`/`Charge` are NOT stateful nodes (a caller's
/// state-reaching-ness flows through the `CallDirect` closure, not this scan).
fn expr_touches_state(expr: Expr) -> Bool {
  case expr {
    MemLoad(..)
    | MemStore(..)
    | MemSize(..)
    | MemGrow(..)
    | GlobalGet(..)
    | GlobalSet(..)
    | CallIndirect(..)
    | // Phase-5 reference/table/bulk nodes all read/write mutable instance state (a table slot,
      // a memory range, passive drop-state, or an instance-linked closure), so a function
      // containing one is state-reaching under `Threaded` (§A.3). No Phase-1..4 module has them.
      ir.RefFunc(..)
    | ir.RefIsNull(..)
    | ir.TableGet(..)
    | ir.TableSet(..)
    | ir.TableSize(..)
    | ir.TableGrow(..)
    | ir.TableFill(..)
    | ir.TableInit(..)
    | ir.TableCopy(..)
    | ir.ElemDrop(..)
    | ir.MemFill(..)
    | ir.MemCopy(..)
    | ir.MemInit(..)
    | ir.DataDrop(..) -> True
    Let(_, rhs, body) -> expr_touches_state(rhs) || expr_touches_state(body)
    If(_, _, t, e) -> expr_touches_state(t) || expr_touches_state(e)
    Switch(_, _, arms, default) ->
      list.any(arms, fn(a) {
        let SwitchArm(_, b) = a
        expr_touches_state(b)
      })
      || expr_touches_state(default)
    Block(_, _, body) -> expr_touches_state(body)
    Loop(_, _, _, body) -> expr_touches_state(body)
    Charge(_, body) -> expr_touches_state(body)
    _ -> False
  }
}

/// Accumulate every `CallDirect` target name reachable in `expr` (the call-graph edges out of
/// a function body). Only `CallDirect` edges — `CallIndirect` targets go through the table, so
/// they are not static edges.
fn direct_callees(expr: Expr, acc: Set(String)) -> Set(String) {
  case expr {
    CallDirect(name, _) -> set.insert(acc, name)
    Let(_, rhs, body) -> direct_callees(body, direct_callees(rhs, acc))
    If(_, _, t, e) -> direct_callees(e, direct_callees(t, acc))
    Switch(_, _, arms, default) -> {
      let acc =
        list.fold(arms, acc, fn(a, arm) {
          let SwitchArm(_, b) = arm
          direct_callees(b, a)
        })
      direct_callees(default, acc)
    }
    Block(_, _, body) -> direct_callees(body, acc)
    Loop(_, _, _, body) -> direct_callees(body, acc)
    Charge(_, body) -> direct_callees(body, acc)
    _ -> acc
  }
}

// ─────────────────────────────── the core emitter ───────────────────────────────

/// Emit `expr` in tail position under continuation `cont` and state channel `sc`, threading
/// `state`.
///
/// Returns the Core expression for `expr` (its yielded values disposed of by `cont`) and
/// the advanced state, or an `EmitError`. The non-returning transfers (`Return`/`Trap`/
/// `Break`/`Continue`) ignore `cont` and emit the transfer directly. Under `Threading(cur)`
/// (§A.2), reads pass `cur`, mutators rebind it, and `Return`/`KReturn` pair the package with
/// the live record; under `NoState` the Phase-2/3 cell code is emitted verbatim.
fn emit(
  expr: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case expr {
    Values(vs) -> apply_cont(cont, list.map(vs, emit_value), sc, state, ctx)
    Return(vs) -> emit_return(vs, sc, state)
    Num(op, args) -> emit_num(op, args, cont, sc, state, ctx)
    Convert(op, arg) -> emit_convert(op, arg, cont, sc, state, ctx)
    CallDirect(fn_name, args) ->
      emit_call_direct(fn_name, args, cont, sc, state, ctx)
    CallHost(cap, name, args) ->
      emit_call_host(cap, name, args, cont, sc, state, ctx)
    Let(names, rhs, body) -> emit(rhs, KBind(names, body, cont), sc, state, ctx)
    If(cond, result, t, e) -> emit_if(cond, result, t, e, cont, sc, state, ctx)
    Switch(sel, result, arms, default) ->
      emit_switch(sel, result, arms, default, cont, sc, state, ctx)
    Block(label, result, body) ->
      emit_block(label, result, body, cont, sc, state, ctx)
    Loop(label, params, result, body) ->
      emit_loop(label, params, result, body, cont, sc, state, ctx)
    Break(label, vs) -> emit_break(label, vs, sc, state, ctx)
    Continue(label, vs) -> emit_continue(label, vs, sc, state)
    Trap(reason) ->
      Ok(#(raise_trap(ctx, CAtom(trap_reason_atom(reason))), state))
    Charge(cost, body) -> emit_charge(cost, body, cont, sc, state, ctx)
    // ── Stateful ops — routed through the ONE state-access seam (`seam_call`). Under
    // `NoState` each is today's cell `call '<binding.X_module>':'op'(...)`; under
    // `Threading(cur)` each threads the `InstanceState` record through the `t_*` family. ──
    // The `mem` index is IGNORED here (always `0` for the Phase-1..4 corpus, so byte-
    // identical); P5-06 adds the leading memory-index argument for `mem != 0`.
    MemSize(_mem) -> emit_mem_size(cont, sc, state, ctx)
    MemGrow(_mem, delta) -> emit_mem_grow(delta, cont, sc, state, ctx)
    MemLoad(_mem, op, addr, offset, result) ->
      emit_mem_load(op, addr, offset, result, cont, sc, state, ctx)
    MemStore(_mem, op, addr, value, offset) ->
      emit_mem_store(op, addr, value, offset, cont, sc, state, ctx)
    GlobalGet(name) -> emit_global_get(name, cont, sc, state, ctx)
    GlobalSet(name, value) -> emit_global_set(name, value, cont, sc, state, ctx)
    CallIndirect(_table, index, ty, args) ->
      emit_call_indirect(index, ty, args, cont, sc, state, ctx)
    // Out of scope — typed error, never a panic. The term layer (`TermOp`) + the term↔numeric
    // boxing `Convert`s remain unlowered, plus the Phase-5 reference/table/bulk nodes whose
    // real codegen is P5-06. No Phase-1..4 module contains any of these, so the corpus + suite
    // stay byte-identical (they are never reached by the existing surface).
    TermOp(..) -> Error(UnsupportedNode("term_op"))
    ir.RefFunc(..) -> Error(UnsupportedNode("ref_func"))
    ir.RefIsNull(..) -> Error(UnsupportedNode("ref_is_null"))
    ir.TableGet(..) -> Error(UnsupportedNode("table_get"))
    ir.TableSet(..) -> Error(UnsupportedNode("table_set"))
    ir.TableSize(..) -> Error(UnsupportedNode("table_size"))
    ir.TableGrow(..) -> Error(UnsupportedNode("table_grow"))
    ir.TableFill(..) -> Error(UnsupportedNode("table_fill"))
    ir.TableInit(..) -> Error(UnsupportedNode("table_init"))
    ir.TableCopy(..) -> Error(UnsupportedNode("table_copy"))
    ir.ElemDrop(..) -> Error(UnsupportedNode("elem_drop"))
    ir.MemFill(..) -> Error(UnsupportedNode("mem_fill"))
    ir.MemCopy(..) -> Error(UnsupportedNode("mem_copy"))
    ir.MemInit(..) -> Error(UnsupportedNode("mem_init"))
    ir.DataDrop(..) -> Error(UnsupportedNode("data_drop"))
  }
}

/// Lower `Return(vs)` (the non-continuation transfer). Under `NoState` it yields the bare
/// `function_return` package; under `Threading(cur)` it pairs that package with the CURRENT
/// live record into the `{Package, St'}` 2-tuple (§B.2).
fn emit_return(
  vs: List(Value),
  sc: StateChan,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  let pkg = function_return(list.map(vs, emit_value))
  case sc {
    NoState -> Ok(#(pkg, state))
    Threading(cur) -> Ok(#(CTuple([pkg, CVar(cur)]), state))
  }
}

// ─────────────────────────── the per-op state seam (cell / threaded) ───────────────────────────

/// `memory.size` (read-only). `NoState`: `call '<mem>':'size'()`. `Threading(cur)`:
/// `call '<mem>':'t_size'(St)` — the record is threaded on UNCHANGED.
fn emit_mem_size(
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState ->
      apply_cont(
        cont,
        [seam_call(ctx.binding.mem_module, "size", [])],
        sc,
        state,
        ctx,
      )
    Threading(cur) ->
      apply_cont(
        cont,
        [seam_call(ctx.binding.mem_module, "t_size", [CVar(cur)])],
        sc,
        state,
        ctx,
      )
  }
}

/// `memory.grow` (effectful). `NoState`: a bare `call '<mem>':'grow'(Delta)` (i32).
/// `Threading(cur)`: `{V, St2} = call '<mem>':'t_grow'(St, Delta)` — bind the old page count
/// `V`, REBIND the record to `St2` (`t_grow` charges the success-path fuel internally, unit
/// 04, so emit charges nothing here).
fn emit_mem_grow(
  delta: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState ->
      apply_cont(
        cont,
        [seam_call(ctx.binding.mem_module, "grow", [emit_value(delta)])],
        sc,
        state,
        ctx,
      )
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.mem_module, "t_grow", [
          CVar(cur),
          emit_value(delta),
        ])
      emit_value_state_pair(call, cont, state, ctx)
    }
  }
}

/// `t.load` (trapping, read-only). `NoState`: `case '<mem>':'load'(Bytes,Signed,W,Addr,Off)`.
/// `Threading(cur)`: `case '<mem>':'t_load'(St, Bytes,Signed,W,Addr,Off)`. Both reduce the
/// trapping `Result(Int, _)` to one value (`emit_trapping_result`); the record is read-only,
/// so `cur` is threaded on unchanged (the surrounding `sc` is preserved).
fn emit_mem_load(
  op: ir.MemAccess,
  addr: Value,
  offset: Int,
  result: ValType,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call = case sc {
    NoState ->
      seam_call(ctx.binding.mem_module, "load", [
        CInt(op.bytes),
        bool_atom(op.signed),
        CInt(result_width(result)),
        emit_value(addr),
        CInt(offset),
      ])
    Threading(cur) ->
      seam_call(ctx.binding.mem_module, "t_load", [
        CVar(cur),
        CInt(op.bytes),
        bool_atom(op.signed),
        CInt(result_width(result)),
        emit_value(addr),
        CInt(offset),
      ])
  }
  emit_trapping_result(call, cont, sc, state, ctx)
}

/// `t.store` (trapping, ZERO-RESULT ordered effect). `op.signed` is irrelevant for stores
/// (`storeN` writes the low N bytes); eval order is addr → value → store (left-to-right `call`
/// args). `NoState`: reduce `{ok,_}`/`{error,E}` to a discardable `'ok'`/`raise` and sequence.
/// `Threading(cur)`: `St2 = case '<mem>':'t_store'(St,…) of {ok,S}->S; {error,R}->raise` —
/// REBIND the record to `St2` (`t_store` returns the updated record); continue under
/// `Threading(St2)` disposing zero values. This makes store-before-load a visible dataflow
/// edge through `St` (stronger than the cell `let`-discard barrier, §G).
fn emit_mem_store(
  op: ir.MemAccess,
  addr: Value,
  value: Value,
  offset: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.mem_module, "store", [
          CInt(op.bytes),
          emit_value(addr),
          emit_value(value),
          CInt(offset),
        ])
      let #(effect, state2) = trapping_effect(call, ctx, state)
      emit_zero_effect(effect, cont, sc, state2, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.mem_module, "t_store", [
          CVar(cur),
          CInt(op.bytes),
          emit_value(addr),
          emit_value(value),
          CInt(offset),
        ])
      emit_threaded_record_effect(call, cont, state, ctx)
    }
  }
}

/// `global.get` (read-only). `NoState`: `call '<state>':'global_get'(NameBin)`.
/// `Threading(cur)`: `call '<state>':'t_global_get'(St, NameBin)` — the record is threaded on
/// unchanged.
fn emit_global_get(
  name: String,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState ->
      apply_cont(
        cont,
        [
          seam_call(ctx.binding.state_module, "global_get", [
            core_binary_string(name),
          ]),
        ],
        sc,
        state,
        ctx,
      )
    Threading(cur) ->
      apply_cont(
        cont,
        [
          seam_call(ctx.binding.state_module, "t_global_get", [
            CVar(cur),
            core_binary_string(name),
          ]),
        ],
        sc,
        state,
        ctx,
      )
  }
}

/// `global.set` (ZERO-RESULT ordered effect). `NoState`: the pure cell effect
/// `call '<state>':'global_set'(NameBin, Val)` sequenced with a `let`-discard.
/// `Threading(cur)`: `St2 = call '<state>':'t_global_set'(St, NameBin, Val)` — NON-trapping,
/// returns the record directly; REBIND `cur := St2` and continue disposing zero values.
fn emit_global_set(
  name: String,
  value: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case sc {
    NoState -> {
      let effect =
        seam_call(ctx.binding.state_module, "global_set", [
          core_binary_string(name),
          emit_value(value),
        ])
      emit_zero_effect(effect, cont, sc, state, ctx)
    }
    Threading(cur) -> {
      let call =
        seam_call(ctx.binding.state_module, "t_global_set", [
          CVar(cur),
          core_binary_string(name),
          emit_value(value),
        ])
      let #(newst, state2) = fresh_var(state)
      use #(rest, state3) <- result.try(apply_cont(
        cont,
        [],
        Threading(newst),
        state2,
        ctx,
      ))
      Ok(#(CLet([newst], call, rest), state3))
    }
  }
}

/// Bind a `#(value, InstanceState)` pair a threaded seam call returns (`t_grow`): a
/// `case <call> of <{V, St2}> when 'true' -> <continue with V under Threading(St2)>`. Used by
/// `memory.grow`, whose runtime returns `#(Int, InstanceState)`.
fn emit_value_state_pair(
  call: CExpr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(vvar, state2) = fresh_var(state)
  let #(stvar, state3) = fresh_var(state2)
  use #(rest, state4) <- result.try(apply_cont(
    cont,
    [CVar(vvar)],
    Threading(stvar),
    state3,
    ctx,
  ))
  Ok(#(
    CCase(call, [
      CClause([PTuple([PVar(vvar), PVar(stvar)])], CAtom("true"), rest),
    ]),
    state4,
  ))
}

/// Sequence a threaded RECORD-rebinding effect: reduce a trapping
/// `Result(InstanceState, TrapReason)` producer to the record on `{ok,S}` (raise on
/// `{error,E}`), bind it to a fresh state var, and continue under `Threading(new)` disposing
/// zero values. Used by `MemStore` (and by the threaded `instantiate` for element/data
/// segments). The `{ok,S}` arm yields the rebound record `S` (not a discardable `'ok'`).
fn emit_threaded_record_effect(
  call: CExpr,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(newst, state2) = fresh_var(state)
  let #(reduced, state3) = record_result_case(call, ctx, state2)
  use #(rest, state4) <- result.try(apply_cont(
    cont,
    [],
    Threading(newst),
    state3,
    ctx,
  ))
  Ok(#(CLet([newst], reduced, rest), state4))
}

/// Reduce a trapping `Result(InstanceState, TrapReason)` producer to the record:
/// `case <call> of <{'ok',S}> -> S; <{'error',E}> -> raise(E) end`. The `{ok,S}` arm yields
/// the rebound record `S`; the `{error,E}` arm raises via `rt_trap`. Both arms yield exactly
/// one value, so the shape is arity-correct in any surrounding context.
fn record_result_case(
  call: CExpr,
  ctx: Ctx,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(svar, state2) = fresh_var(state)
  let #(evar, state3) = fresh_var(state2)
  let reduced =
    CCase(call, [
      CClause([PTuple([PAtom("ok"), PVar(svar)])], CAtom("true"), CVar(svar)),
      CClause(
        [PTuple([PAtom("error"), PVar(evar)])],
        CAtom("true"),
        raise_trap(ctx, CVar(evar)),
      ),
    ])
  #(reduced, state3)
}

/// Dispose of the produced `vals` according to `cont`, under state channel `sc`.
///
/// - `KReturn`: `NoState` → yield `vals` as the `function_return` package; `Threading(cur)` →
///   pair it with the live record into `{Package, cur}` (§B.2).
/// - `KJump(target)`: `NoState` → tail-apply the join point `apply target(vals)`;
///   `Threading(cur)` → PREPEND the live record `apply target(cur, vals)` (the join was
///   widened by one leading state slot, §D).
/// - `KBind(names, body, next)`: bind `vals` to `names` (`ArityMismatch` if the counts
///   differ), then emit `body` under `next` — `sc` flows through unchanged (a bound value
///   list is state-neutral).
fn apply_cont(
  cont: Cont,
  vals: List(CExpr),
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case cont {
    KReturn ->
      case sc {
        NoState -> Ok(#(function_return(vals), state))
        Threading(cur) ->
          Ok(#(CTuple([function_return(vals), CVar(cur)]), state))
      }
    KJump(target) ->
      case sc {
        NoState -> Ok(#(CApply(target, vals), state))
        Threading(cur) -> Ok(#(CApply(target, [CVar(cur), ..vals]), state))
      }
    KBind(names, body, next) ->
      case list.length(names) == list.length(vals) {
        False -> Error(ArityMismatch(list.length(names), list.length(vals)))
        True -> {
          use #(body_c, state2) <- result.try(emit(body, next, sc, state, ctx))
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
///
/// The `KReturn` STRAIGHT-THROUGH (yield `produced` unpackaged) is sound ONLY under
/// `NoState`: there the caller's own result is the same `r`-valued package. Under
/// `Threading(cur)` the caller must return `{Package, cur}`, so `produced` cannot be yielded
/// bare — it is unpacked into `r` values and re-disposed through `KReturn`, which pairs the
/// re-formed package with `cur`. (A THREADED callee's `{Package, St'}` tail call is handled
/// by `emit_call_direct` directly, preserving the cross-function tail call, §B.3.)
fn apply_cont_call(
  cont: Cont,
  produced: CExpr,
  r: Int,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case cont, sc {
    KReturn, NoState -> Ok(#(produced, state))
    _, _ -> apply_cont_call_unpack(cont, produced, r, sc, state, ctx)
  }
}

/// Unpack a single `function_return`-packaged value `produced` into its `r` values and
/// dispose them through `cont` under `sc`: `r==0` binds+discards the dummy (keeping the
/// effect); `r==1` continues with the bare value; `r>=2` destructures the `{V1,…,Vr}` tuple.
fn apply_cont_call_unpack(
  cont: Cont,
  produced: CExpr,
  r: Int,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case r {
    0 -> {
      let #(g, state2) = fresh_var(state)
      use #(rest, state3) <- result.try(apply_cont(cont, [], sc, state2, ctx))
      Ok(#(CLet([g], produced, rest), state3))
    }
    1 -> apply_cont(cont, [produced], sc, state, ctx)
    _ -> {
      let #(names, state2) = fresh_n_vars(state, r)
      use #(rest, state3) <- result.try(apply_cont(
        cont,
        list.map(names, CVar),
        sc,
        state2,
        ctx,
      ))
      let clause = CClause([PTuple(list.map(names, PVar))], CAtom("true"), rest)
      Ok(#(CCase(produced, [clause]), state3))
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

/// Materialise `cont` into a shared join point if it is non-trivial, under state channel `sc`.
///
/// `arity` is the number of values the multi-exit construct yields. A `KBind` continuation
/// is lowered to a `letrec` join `fun(names…) -> <body under next>`; the returned `Cont`
/// becomes `KJump('J')` so every exit tail-applies it once. A trivial continuation
/// (`KReturn`/`KJump`) is returned unchanged with no join point. `ArityMismatch` if the
/// bind's name count differs from `arity`.
///
/// Under `Threading(_)` the join is WIDENED by one leading state slot (§D):
/// `'J'/(arity+1) = fun(St, names…) -> <body under Threading(St)>`. Every exit appends its
/// live record to the value list (`apply_cont`'s `KJump` prepend), so the branches' differing
/// records UNIFY at the merge — the natural functional join, in constant stack (the join
/// `apply` stays a tail call). Under `NoState` the Phase-2/3 join is emitted verbatim.
fn materialize(
  cont: Cont,
  arity: Int,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(Option(FunDef), Cont, EmitState), EmitError) {
  case cont {
    KReturn -> Ok(#(None, KReturn, state))
    KJump(t) -> Ok(#(None, KJump(t), state))
    KBind(names, body, next) ->
      case list.length(names) == arity {
        False -> Error(ArityMismatch(arity, list.length(names)))
        True ->
          case sc {
            NoState -> {
              let #(jname, state2) = fresh_fn(state)
              let fname = FName(jname, arity)
              use #(jbody, state3) <- result.try(emit(
                body,
                next,
                NoState,
                state2,
                ctx,
              ))
              Ok(#(
                Some(FunDef(fname, CFun(names, jbody))),
                KJump(fname),
                state3,
              ))
            }
            Threading(_) -> {
              let #(jname, state2) = fresh_fn(state)
              let #(st_join, state3) = fresh_var(state2)
              let fname = FName(jname, arity + 1)
              use #(jbody, state4) <- result.try(emit(
                body,
                next,
                Threading(st_join),
                state3,
                ctx,
              ))
              Ok(#(
                Some(FunDef(fname, CFun([st_join, ..names], jbody))),
                KJump(fname),
                state4,
              ))
            }
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
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let call =
    seam_call(
      ctx.binding.num_module,
      num_op_name(op),
      list.map(args, emit_value),
    )
  case is_trapping(op) {
    False -> apply_cont(cont, [call], sc, state, ctx)
    True -> emit_trapping_result(call, cont, sc, state, ctx)
  }
}

// ─────────────────────────── the state-access seam + dispositions ───────────────────────────

/// Emit a direct call to a fixed runtime module field of the `Binding` — THE state-access
/// seam (E1). `module` is always a build-controlled `twocore@runtime@*` atom (one of
/// `binding.{num,trap,host,meter,stdlib,mem,table,state}_module`), never a program value;
/// `fn_name` is always a literal atom (D3a — no ambient authority). For the cell strategy
/// every stateful op is a `call '<module>':'<fn_name>'(args)`; the Phase-3 `threaded`
/// retrofit expands THIS one helper rather than every op site.
fn seam_call(module: String, fn_name: String, args: List(CExpr)) -> CExpr {
  CCall(CAtom(module), CAtom(fn_name), args)
}

/// Dispose a trapping `Result(Int, TrapReason)` producer — the verified `case`-and-`raise`
/// shape shared by trapping `Num`, `MemLoad`, and trapping `Convert`.
///
/// A trapping op yields EXACTLY ONE value (or raises). Reduce it to a single bound variable
/// `rvar` via a `case` whose BOTH clauses yield one value — the unwrapped `{ok,X}` result,
/// or the never-returning `raise` on `{error,E}` — then thread that single value through
/// `cont` normally. Binding once and threading once keeps the two `case` arms arity-
/// consistent (both yield 1) regardless of the surrounding value-list arity: a 0-result
/// function (`cont` yields `<>`) or a multi-value join point would break a structure that
/// inlined `cont` into only the `ok` arm, because then the `error` arm's lone `raise` value
/// would disagree with the `ok` arm's arity (the Core compiler rejects that as a "return
/// count mismatch").
fn emit_trapping_result(
  produced: CExpr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(xvar, state2) = fresh_var(state)
  let #(evar, state3) = fresh_var(state2)
  let #(rvar, state4) = fresh_var(state3)
  let result_case =
    CCase(produced, [
      CClause([PTuple([PAtom("ok"), PVar(xvar)])], CAtom("true"), CVar(xvar)),
      CClause(
        [PTuple([PAtom("error"), PVar(evar)])],
        CAtom("true"),
        raise_trap(ctx, CVar(evar)),
      ),
    ])
  use #(rest, state5) <- result.try(apply_cont(
    cont,
    [CVar(rvar)],
    sc,
    state4,
    ctx,
  ))
  Ok(#(CLet([rvar], result_case, rest), state5))
}

/// Reduce a trapping zero-result `Result(Nil, TrapReason)` producer (`MemStore`,
/// `init_elem`, `init_data`) to a SINGLE discardable value: `{ok,_}` → `'ok'`,
/// `{error,E}` → `raise(E)`. Returns the reduced `case` expression (one value), ready to be
/// sequenced as an ordered effect by `emit_zero_effect`.
fn trapping_effect(
  call: CExpr,
  ctx: Ctx,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(wild, state2) = fresh_var(state)
  let #(evar, state3) = fresh_var(state2)
  let reduced =
    CCase(call, [
      CClause([PTuple([PAtom("ok"), PVar(wild)])], CAtom("true"), CAtom("ok")),
      CClause(
        [PTuple([PAtom("error"), PVar(evar)])],
        CAtom("true"),
        raise_trap(ctx, CVar(evar)),
      ),
    ])
  #(reduced, state3)
}

/// Sequence a ZERO-RESULT ordered effect: `let <g> = <effect> in <rest>` with `g`
/// discarded and `<rest>` emitted under `cont` disposing ZERO values. Non-DCE, non-
/// reorderable (E6): Core `let` is strict, so the effect always runs before `<rest>` and
/// is never eliminated.
fn emit_zero_effect(
  effect: CExpr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(g, state2) = fresh_var(state)
  use #(rest, state3) <- result.try(apply_cont(cont, [], sc, state2, ctx))
  Ok(#(CLet([g], effect, rest), state3))
}

/// The Erlang atom `'true'`/`'false'` for a `Bool` — `MemLoad`'s `Signed` argument.
fn bool_atom(b: Bool) -> CExpr {
  case b {
    True -> CAtom("true")
    False -> CAtom("false")
  }
}

/// The load result width in bits — `W(result)` from the load's result `ValType`: 32 for
/// `TI32`/`TF32`, 64 for `TI64`/`TF64` (raw-bits rep: `f32.load` == `i32.load` byte-wise, so
/// only width+sign matter). `TTerm` cannot be a numeric load result; defaulted to 32.
fn result_width(t: ValType) -> Int {
  case t {
    TI32 | TF32 | TTerm -> 32
    TI64 | TF64 -> 64
    // Reference types are never a numeric load result (validate rejects it); defaulted to 32.
    ir.TFuncRef | ir.TExternRef -> 32
  }
}

/// Lower a `Convert` op. Numeric width/sign/reinterpret/saturating-truncation/int→float/
/// demote/promote conversions route through `binding.num_module` (the same chokepoint) as a
/// bare `call` (total — never traps). The TRAPPING float→int truncations (`TruncS`/`TruncU`)
/// return `Result(Int, TrapReason)` and route through the verified `case`-and-`raise` shape
/// (`emit_trapping_result`), exactly like `IDivS` — `is_trapping_conv` decides which. The
/// four term↔numeric boxing conversions remain out of scope → `Error(UnsupportedNode)`.
fn emit_convert(
  op: ConvOp,
  arg: Value,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case conv_op_name(op) {
    Error(node) -> Error(UnsupportedNode(node))
    Ok(fn_name) -> {
      let call = seam_call(ctx.binding.num_module, fn_name, [emit_value(arg)])
      case is_trapping_conv(op) {
        True -> emit_trapping_result(call, cont, sc, state, ctx)
        False -> apply_cont(cont, [call], sc, state, ctx)
      }
    }
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
///
/// Under `Threading(cur)` with a STATE-REACHING callee `g`, the record is threaded:
/// `apply 'g'/(n+1)(cur, args…)` yields `{Package, St'}`.
/// - `cont == KReturn` → emit the `apply` STRAIGHT THROUGH — `{Package, St'}` is already
///   exactly what the caller must return, so a tail `CallDirect` to a threaded callee stays a
///   TAIL CALL (cross-function tail recursion keeps constant stack, §B.3).
/// - otherwise → `case {Pkg, St'} -> …` destructures the pair, unpacks `Pkg` into `r` values,
///   and continues under `Threading(St')`.
/// A PURE callee is `apply 'g'/n(args…)` with `cur` flowing AROUND it unchanged (dispatched
/// by `apply_cont_call`, which under `Threading` re-pairs the result with `cur` at `KReturn`).
fn emit_call_direct(
  fn_name: String,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case dict.get(ctx.fn_arity, fn_name) {
    Error(_) -> Error(UnknownFunction(fn_name))
    Ok(arity) -> {
      let r = result.unwrap(dict.get(ctx.fn_results, fn_name), 1)
      let cargs = list.map(args, emit_value)
      let callee_threaded =
        is_threaded(ctx) && set.contains(ctx.fn_state_reaching, fn_name)
      case sc, callee_threaded {
        Threading(cur), True -> {
          let applied = CApply(FName(fn_name, arity + 1), [CVar(cur), ..cargs])
          case cont {
            KReturn -> Ok(#(applied, state))
            _ -> emit_threaded_call_unpack(applied, r, cont, state, ctx)
          }
        }
        _, _ ->
          apply_cont_call(
            cont,
            CApply(FName(fn_name, arity), cargs),
            r,
            sc,
            state,
            ctx,
          )
      }
    }
  }
}

/// Destructure a threaded callee's `{Package, St'}` at a NON-tail site: `case <applied> of
/// <{Pkg, St'}> -> <unpack Pkg into r values, continue under Threading(St')>`. Unpacking `Pkg`
/// reuses the same `r∈{0,1,≥2}` logic as a pure call (`apply_cont_call`).
fn emit_threaded_call_unpack(
  applied: CExpr,
  r: Int,
  cont: Cont,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(pkgvar, state2) = fresh_var(state)
  let #(stvar, state3) = fresh_var(state2)
  use #(rest, state4) <- result.try(apply_cont_call(
    cont,
    CVar(pkgvar),
    r,
    Threading(stvar),
    state3,
    ctx,
  ))
  Ok(#(
    CCase(applied, [
      CClause([PTuple([PVar(pkgvar), PVar(stvar)])], CAtom("true"), rest),
    ]),
    state4,
  ))
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
/// emitted as BINARY STRINGS — the exact type `rt_host.call_host` consumes, so its
/// `resolve_handler`/`HostWhitelist` string matching actually fires under a permissive
/// (`HostOpen`/`HostWhitelist`) posture (F4), and the deny-all `{capability_denied, Cap,
/// Name}` echoes them as binaries (consistent with a direct Gleam-side call). Emitting them
/// as atoms — faithful only for deny-all, which inspects nothing — would make an admitting
/// host silently deny every handler (an atom never matches the `String` patterns).
fn emit_call_host(
  capability: String,
  name: String,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let cargs = list.map(args, emit_value)
  case resolve_stdlib(capability, name) {
    Some(fn_name) ->
      // A vetted `own`-stdlib call yields a single value (Phase-1: `gcd/2`). State-neutral:
      // the host boundary never touches the record, so `cur` flows through unchanged (§G).
      apply_cont_call(
        cont,
        CCall(CAtom(ctx.binding.stdlib_module), CAtom(fn_name), cargs),
        1,
        sc,
        state,
        ctx,
      )
    None -> {
      // The host yields a single value or raises (`{capability_denied,…}`). `capability`/`name`
      // are emitted as BINARY STRINGS so `rt_host`'s handler/whitelist matching (which pattern-
      // matches Gleam `String`s) fires under a permissive posture, not just deny-all.
      let call =
        CCall(CAtom(ctx.binding.host_module), CAtom("call_host"), [
          core_binary_string(capability),
          core_binary_string(name),
          core_list(cargs),
        ])
      apply_cont_call(cont, call, 1, sc, state, ctx)
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

/// Lower a `CallIndirect` to the 3-fault, ambient-free dispatch (E3): a single seam call
/// `call '<table_module>':'call_indirect'(Idx, TypeTag, ArgList)` — the runtime type-check
/// and the three traps (bounds → null → type) live INSIDE `rt_table`, never here.
///
/// - `index`: the runtime table index — the ONLY program-derived value that reaches the
///   dispatch. The dispatched target is a build-controlled closure stored in the slot at
///   instantiation (never `apply(Mod, F, Args)` with `Mod`/`F` from data) — D3a.
/// - `ty`: the call-site's expected `FuncType`, emitted as a compile-time-canonical
///   `TypeTag` term via `func_type_term` (the SAME renderer the element-segment entry uses,
///   so `rt_table`'s structural `==` guard holds at run time).
/// - `args`: spread into a proper Core list `ArgList`.
///
/// The result is `Result(List(Int), TrapReason)`: `{ok,V}`/`{error,R}` → `case`-and-`raise`
/// (`emit_trapping_result`) binding the result LIST `V`, then the list is unpacked into
/// `len(ty.results)` values and disposed through `cont`. The IR's `table` name is ignored
/// (the MVP cell holds a single funcref table).
fn emit_call_indirect(
  index: Value,
  ty: FuncType,
  args: List(Value),
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let r = list.length(ty.results)
  case sc {
    NoState -> {
      let call =
        seam_call(ctx.binding.table_module, "call_indirect", [
          emit_value(index),
          func_type_term(ty),
          core_list(list.map(args, emit_value)),
        ])
      // Bind one var to the unwrapped result LIST (or raise on `{error,R}`), then unpack it.
      let #(xvar, state2) = fresh_var(state)
      let #(evar, state3) = fresh_var(state2)
      let #(lvar, state4) = fresh_var(state3)
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
      use #(rest, state5) <- result.try(unpack_result_list(
        lvar,
        r,
        cont,
        sc,
        state4,
        ctx,
      ))
      Ok(#(CLet([lvar], result_case, rest), state5))
    }
    Threading(cur) -> {
      // `{Rs, St2} = case '<table>':'t_call_indirect'(St, Idx, TypeTag, Args) of
      //   {ok,P} -> P; {error,R} -> raise end` — unpack `Rs` to `len(ty.results)` values,
      // REBIND `cur := St2`. `t_call_indirect` returns `#(List(Int), InstanceState)`.
      let call =
        seam_call(ctx.binding.table_module, "t_call_indirect", [
          CVar(cur),
          emit_value(index),
          func_type_term(ty),
          core_list(list.map(args, emit_value)),
        ])
      let #(pvar, state2) = fresh_var(state)
      let #(evar, state3) = fresh_var(state2)
      let #(pbound, state4) = fresh_var(state3)
      let result_case =
        CCase(call, [
          CClause(
            [PTuple([PAtom("ok"), PVar(pvar)])],
            CAtom("true"),
            CVar(pvar),
          ),
          CClause(
            [PTuple([PAtom("error"), PVar(evar)])],
            CAtom("true"),
            raise_trap(ctx, CVar(evar)),
          ),
        ])
      // Destructure `pbound = {Rs, St2}`, then unpack `Rs` under `Threading(St2)`.
      let #(rsvar, state5) = fresh_var(state4)
      let #(stvar, state6) = fresh_var(state5)
      use #(rest, state7) <- result.try(unpack_result_list(
        rsvar,
        r,
        cont,
        Threading(stvar),
        state6,
        ctx,
      ))
      let destructure =
        CCase(CVar(pbound), [
          CClause([PTuple([PVar(rsvar), PVar(stvar)])], CAtom("true"), rest),
        ])
      Ok(#(CLet([pbound], result_case, destructure), state7))
    }
  }
}

/// Unpack the result LIST bound to `lvar` (length `r`, the callee's result count) into `r`
/// Core values and dispose them through `cont`. `r == 0` disposes zero values (the list is
/// `[]`, discarded); otherwise a `case lvar of <[V1,…,Vr]> -> …` destructures the list and
/// continues with the elements.
fn unpack_result_list(
  lvar: String,
  r: Int,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  case r {
    0 -> apply_cont(cont, [], sc, state, ctx)
    _ -> {
      let #(names, state2) = fresh_n_vars(state, r)
      use #(rest, state3) <- result.try(apply_cont(
        cont,
        list.map(names, CVar),
        sc,
        state2,
        ctx,
      ))
      let clause = CClause([list_pattern(names)], CAtom("true"), rest)
      Ok(#(CCase(CVar(lvar), [clause]), state3))
    }
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
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, jcont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  use #(then_c, state3) <- result.try(emit(then_branch, jcont, sc, state2, ctx))
  use #(else_c, state4) <- result.try(emit(else_branch, jcont, sc, state3, ctx))
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
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, jcont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  use #(arm_clauses, state3) <- result.try(
    emit_switch_arms(arms, jcont, sc, state2, ctx, []),
  )
  use #(default_c, state4) <- result.try(emit(default, jcont, sc, state3, ctx))
  let #(wild, state5) = fresh_var(state4)
  let clauses =
    list.append(arm_clauses, [CClause([PVar(wild)], CAtom("true"), default_c)])
  Ok(#(wrap_join(maybe_def, CCase(emit_value(selector), clauses)), state5))
}

/// Emit the `Switch` arm clauses, threading state (accumulator in reverse).
fn emit_switch_arms(
  arms: List(SwitchArm),
  jcont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
  acc: List(CClause),
) -> Result(#(List(CClause), EmitState), EmitError) {
  case arms {
    [] -> Ok(#(list.reverse(acc), state))
    [SwitchArm(match, body), ..rest] -> {
      use #(body_c, state2) <- result.try(emit(body, jcont, sc, state, ctx))
      let clause = CClause([PInt(match)], CAtom("true"), body_c)
      emit_switch_arms(rest, jcont, sc, state2, ctx, [clause, ..acc])
    }
  }
}

/// Lower `Block` to a forward continuation. A non-trivial continuation is materialised into
/// a join point; the block body is emitted with both fall-through and `Break(label, …)`
/// resolving to that exit continuation (so the code after the block is emitted once). Under
/// `Threading`, the materialised join carries the record (§D) and each exit prepends its live
/// record (`apply_cont`'s `KJump`).
fn emit_block(
  label: String,
  result: List(ir.ValType),
  body: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use #(maybe_def, exit_cont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  let state3 = push_label(state2, LabelEntry(label, exit_cont, None))
  use #(body_c, state4) <- result.try(emit(body, exit_cont, sc, state3, ctx))
  let state5 = restore_labels(state4, state2.labels)
  Ok(#(wrap_join(maybe_def, body_c), state5))
}

/// Lower `Loop` to the verified §5 template: `letrec 'L'/arity = fun(params…) -> <body>`
/// applied to the loop-param inits. `Continue(label, vs)` becomes a tail `apply 'L'(vs)`
/// (the back-edge → constant space); fall-through and `Break(label, …)` exit through the
/// (materialised) continuation.
///
/// Under `Threading(cur)` (the G4 crux), the record is carried as the LEADING loop param:
/// `letrec 'L'/(k+1) = fun(St, P1…Pk) -> <body under Threading(St)>` applied to
/// `apply 'L'(St_entry, Init1…Initk)`. `Continue` prepends the LIVE record
/// (`apply 'L'(St', vs…)`) and `Break`/fall-through prepend the exit record. The back-edge
/// stays a TAIL `apply`, and the `InstanceState` is a fixed-size box, so threading it does NOT
/// grow the stack — constant space and preemption are preserved.
fn emit_loop(
  label: String,
  params: List(ir.LoopParam),
  result: List(ir.ValType),
  body: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let arity = list.length(params)
  use #(maybe_def, exit_cont, state2) <- result.try(materialize(
    cont,
    list.length(result),
    sc,
    state,
    ctx,
  ))
  let #(lname, state3) = fresh_fn(state2)
  case sc {
    NoState -> {
      let lfname = FName(lname, arity)
      let state4 =
        push_label(state3, LabelEntry(label, exit_cont, Some(lfname)))
      use #(body_c, state5) <- result.try(emit(
        body,
        exit_cont,
        NoState,
        state4,
        ctx,
      ))
      let state6 = restore_labels(state5, state3.labels)
      let param_names = list.map(params, fn(p) { p.name })
      let inits = list.map(params, fn(p) { emit_value(p.init) })
      let loop_def = FunDef(lfname, CFun(param_names, body_c))
      let loop_expr = CLetrec([loop_def], CApply(lfname, inits))
      Ok(#(wrap_join(maybe_def, loop_expr), state6))
    }
    Threading(cur) -> {
      let #(st_loop, state3b) = fresh_var(state3)
      let lfname = FName(lname, arity + 1)
      let state4 =
        push_label(state3b, LabelEntry(label, exit_cont, Some(lfname)))
      use #(body_c, state5) <- result.try(emit(
        body,
        exit_cont,
        Threading(st_loop),
        state4,
        ctx,
      ))
      let state6 = restore_labels(state5, state3b.labels)
      let param_names = [st_loop, ..list.map(params, fn(p) { p.name })]
      let inits = [CVar(cur), ..list.map(params, fn(p) { emit_value(p.init) })]
      let loop_def = FunDef(lfname, CFun(param_names, body_c))
      let loop_expr = CLetrec([loop_def], CApply(lfname, inits))
      Ok(#(wrap_join(maybe_def, loop_expr), state6))
    }
  }
}

/// Lower `Break(label, vs)`: resolve the label's exit continuation and dispose `vs`
/// through it (under the break-site's `sc`, so a threaded break prepends its live record).
/// `Error(UnboundLabel)` if the label is not in scope.
fn emit_break(
  label: String,
  vs: List(Value),
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  use entry <- result.try(find_label(state, label))
  apply_cont(entry.break_cont, list.map(vs, emit_value), sc, state, ctx)
}

/// Lower `Continue(label, vs)`: tail-apply the loop head `apply 'L'(vs)` — under
/// `Threading(cur)` the LIVE record leads (`apply 'L'(cur, vs)`), keeping the back-edge a tail
/// call (constant space). `Error(UnboundLabel)` if the label is not in scope or names a
/// `Block` (no back-edge).
fn emit_continue(
  label: String,
  vs: List(Value),
  sc: StateChan,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  use entry <- result.try(find_label(state, label))
  case entry.continue_target {
    Some(lfname) ->
      case sc {
        NoState -> Ok(#(CApply(lfname, list.map(vs, emit_value)), state))
        Threading(cur) ->
          Ok(#(CApply(lfname, [CVar(cur), ..list.map(vs, emit_value)]), state))
      }
    None -> Error(UnboundLabel(label))
  }
}

/// Lower `Charge(cost, body)` to the metering seam (D9): `let _ =
/// call '<meter_module>':'charge'(Cost) in <body>`. State-neutral — `charge` never touches the
/// record, so `sc` (and the live `cur`) flows through `body` unchanged (§G).
fn emit_charge(
  cost: Int,
  body: Expr,
  cont: Cont,
  sc: StateChan,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(CExpr, EmitState), EmitError) {
  let #(wild, state2) = fresh_var(state)
  use #(body_c, state3) <- result.try(emit(body, cont, sc, state2, ctx))
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
    // The null-reference literal (both reftypes share ONE sentinel, R1) — the forge-proof
    // `{ref_null}` term `rt_ref.null_ref` produces. Reftype-agnostic at runtime. No Phase-1..4
    // operand is `ConstNull`, so this arm is never reached by the existing corpus.
    ir.ConstNull(_ty) -> CTuple([CAtom("ref_null")])
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

/// A proper Core LIST PATTERN `[N1, N2, …]` of variable binders (`PCons` chain ending in
/// `PNil`). Used to destructure a `call_indirect` result list and a closure's args list.
fn list_pattern(names: List(String)) -> CPat {
  list.fold_right(names, PNil, fn(acc, n) { PCons(PVar(n), acc) })
}

// ─────────────────────────────── the FuncType / binary-literal renderers ───────────────────────────────

/// Render an `ir.FuncType` as a build-controlled, compile-time-canonical Core TERM
/// `{[paramtype-atoms…], [resulttype-atoms…]}` — the `call_indirect` `TypeTag`.
///
/// This is the SINGLE renderer used at BOTH the call site (the expected type) and the
/// element-segment entry (the slot's stored type tag), so `rt_table`'s exact structural
/// guard `entry_type == expected_type` holds at run time (both terms are byte-identical when
/// the `FuncType`s are structurally equal). `rt_table` never inspects the term's shape — it
/// only stores and `==`-compares it — so any canonical encoding works provided it is
/// produced here and nowhere else.
fn func_type_term(ty: FuncType) -> CExpr {
  let FuncType(params, results) = ty
  CTuple([
    core_list(list.map(params, valtype_atom)),
    core_list(list.map(results, valtype_atom)),
  ])
}

/// The canonical valtype atom used inside a `func_type_term` (`'i32'`/`'i64'`/`'f32'`/
/// `'f64'`/`'term'`). Self-consistent — only its use on both sides of the `==` guard matters.
fn valtype_atom(t: ValType) -> CExpr {
  CAtom(case t {
    TI32 -> "i32"
    TI64 -> "i64"
    TF32 -> "f32"
    TF64 -> "f64"
    TTerm -> "term"
    ir.TFuncRef -> "funcref"
    ir.TExternRef -> "externref"
  })
}

/// A Core binary STRING literal of `s`'s UTF-8 bytes (e.g. `"g0"` → `<<"g0">>`), byte-exact
/// with the BEAM binary a Gleam `String` is — so `rt_state.global_get(name: String)` /
/// `seed`'s global-name keys match. Emitted as a `CBinary` of 8-bit integer segments.
fn core_binary_string(s: String) -> CExpr {
  core_binary_bytes(bit_array.from_string(s))
}

/// A Core binary literal of the raw `bytes` (a data-segment payload), each byte an 8-bit
/// `'integer'` segment — byte-exact with a BEAM `binary`/Gleam `BitArray`.
fn core_binary_bytes(bytes: BitArray) -> CExpr {
  CBinary(byte_segments(bytes, []))
}

/// Peel `bytes` into one little-endian-irrelevant 8-bit segment per byte (accumulated in
/// reverse, then restored). A non-byte-aligned tail (never produced here) ends the scan.
fn byte_segments(bytes: BitArray, acc: List(CBitSeg)) -> List(CBitSeg) {
  case bytes {
    <<b:size(8), rest:bits>> -> byte_segments(rest, [byte_seg(b), ..acc])
    _ -> list.reverse(acc)
  }
}

/// One unsigned 8-bit integer binary segment `#<B>(8,1,'integer',['unsigned','big'])`.
fn byte_seg(b: Int) -> CBitSeg {
  CBitSeg(value: CInt(b), size: CInt(8), unit: 1, segtype: "integer", flags: [
    "unsigned",
    "big",
  ])
}

// ─────────────────────────────── the instantiate/0 entry (E5) ───────────────────────────────

/// Emit the generated `'instantiate'/0` entry (the frozen instantiation contract, §C).
///
/// This is the ONE documented exception to `emit_core`'s posture-agnosticism (module doc,
/// F4/F6/F7): it is the sole owner of the per-instance runtime SEEDS, so it — and only it —
/// reads policy fields (`meter`/`fuel_budget`/`host_policy`). Its body runs, in order, inside
/// the instance's owned process:
///
/// - (0a) **when `binding.meter == MeterFuel`** — `rt_meter:seed_fuel(binding.fuel_budget)` as
///   the FIRST effect, arming the fail-closed CPU bound BEFORE any `charge` can fire (F5/D4).
///   Under `MeterOff` no `seed_fuel` line is emitted (there are no `Charge` sites to bound).
/// - (0b) **always** — `rt_host:seed_policy(binding.host_policy)` with `host_policy` baked as a
///   Core Erlang literal (F4/F7). Safe seeds `host_deny_all`, Unsafe seeds `host_open`;
///   seeding always keeps the boundary explicit (an unseeded policy already defaults deny-all).
/// - (1) seed the FRESH per-instance cell (`rt_state:seed` with a build-controlled `StateDecl`
///   term whose `mem = rt_mem:fresh(min, max, safe_cap)`, `table = rt_table:new(min, max)`, and
///   globals from their constant-folded inits); (2) write each active ELEMENT segment
///   (`rt_table:init_elem`); (3) write each active DATA segment (`rt_mem:init_data`); (4) run
///   the `start` function. Element BEFORE data (spec instantiation order). Steps 2–4 are
///   trap-at-instantiation: each is reduced to one discardable value (`{ok,_}` → `'ok'`,
///   `{error,E}` → `raise`) and `let`-sequenced, so a segment-OOB / trapping-start raises and
///   fails instantiation. The body returns `'ok'` on success.
///
/// The two seed lines are the ONLY difference between `emit_module(m, safe())` and
/// `emit_module(m, unsafe())` beyond the `Charge` nodes already differing in the incoming IR
/// (§A.4). Both target fixed `Binding` runtime atoms (`meter_module`/`host_module`), so they
/// pass the no-ambient-authority walk unchanged (D3a). They run once per instance, never on a
/// hot path — so F5 zero-overhead on metered functions is untouched.
///
/// Returns `Error(NonConstInit)` if a global init / segment offset is not a constant
/// literal, or `Error(UnknownFunction)` if an element/`start` function is undefined.
///
/// Under `state_strategy: Threaded` the body instead BUILDS and RETURNS the `InstanceState`
/// record (`emit_instantiate_threaded`, §E); the `seed_fuel`/`seed_policy` seeds are unchanged
/// (metering/host are pdict-seeded — orthogonal to state threading).
fn emit_instantiate(module: Module, ctx: Ctx) -> Result(FunDef, EmitError) {
  case is_threaded(ctx) {
    False -> emit_instantiate_cell(module, ctx)
    True -> emit_instantiate_threaded(module, ctx)
  }
}

/// The `Cell` `instantiate/0` (byte-identical to Phase 2/3): seed the pdict cell
/// (`rt_state:seed(Decl)` as a `let`-discard), write element → data segments, run `start`, and
/// return `'ok'`. Every step is a zero-result ordered effect chained with `chain_effects`.
fn emit_instantiate_cell(
  module: Module,
  ctx: Ctx,
) -> Result(FunDef, EmitError) {
  let state0 =
    EmitState(
      counter: 0,
      vars: set.new(),
      fns: set.from_list(dict.keys(ctx.fn_arity)),
      labels: [],
    )
  use #(decl_term, state1) <- result.try(state_decl_term(module, ctx, state0))
  let seed_effect = seam_call(ctx.binding.state_module, "seed", [decl_term])
  use #(elem_fx, state2) <- result.try(element_segment_effects(
    module.elements,
    ctx,
    state1,
  ))
  use #(data_fx, state3) <- result.try(data_segment_effects(
    module.data_segments,
    ctx,
    state2,
  ))
  use start_fx <- result.try(start_effects(module, ctx))
  let effects =
    list.flatten([
      seed_fuel_effect(ctx),
      seed_policy_effect(ctx),
      [seed_effect],
      elem_fx,
      data_fx,
      start_fx,
    ])
  let #(body, _state4) = chain_effects(effects, state3)
  Ok(FunDef(FName("instantiate", 0), CFun([], body)))
}

/// The `Threaded` `instantiate/0` (§E) — BUILDS and RETURNS the `InstanceState` record
/// instead of seeding the pdict. The body, in order:
///
/// - (0a/0b) `seed_fuel` (MeterFuel only) / `seed_policy` — UNCHANGED `let`-discards (metering
///   and the host boundary are pdict-seeded, orthogonal to state threading, F5/F4).
/// - (1) `St0 = call '<state>':'fresh'(Decl)` — the SAME `Decl` term the cell strategy passes
///   to `seed`, but its consumer is `fresh(Decl) -> InstanceState` (bound, not discarded), so a
///   `Threaded` and a `Cell` build start from byte-identical state (G7).
/// - (2) each active ELEMENT segment: `St' = case '<table>':'t_init_elem'(St, Off, Entries) of
///   {ok,S}->S; {error,E}->raise` — rebinds the record; `Entries` are the THREADED closures
///   (`fun(St, Args) -> {Results, St'}`, §C).
/// - (3) each active DATA segment: `St' = case '<mem>':'t_init_data'(St, Off, Bytes) of …`.
/// - (4) `start` (WASM `[]→[]`): a STATE-REACHING start threads
///   `{_, St'} = apply 'f<start>'/(a+1)(St)`; a PURE start is `apply 'f<start>'/a()` with the
///   record unchanged. Element BEFORE data BEFORE start (spec instantiation order); a
///   segment-OOB / trapping start raises and fails instantiation, abandoning the record.
/// - (5) RETURN the final `InstanceState` (not `'ok'`).
fn emit_instantiate_threaded(
  module: Module,
  ctx: Ctx,
) -> Result(FunDef, EmitError) {
  let state0 =
    EmitState(
      counter: 0,
      vars: set.new(),
      fns: set.from_list(dict.keys(ctx.fn_arity)),
      labels: [],
    )
  use #(decl_term, state1) <- result.try(state_decl_term(module, ctx, state0))
  // (0) The unchanged metering/host seed discards.
  let seed_effects =
    list.flatten([seed_fuel_effect(ctx), seed_policy_effect(ctx)])
  let #(seed_wraps, state2) = discard_wrappers(seed_effects, state1)
  // (1) St0 = fresh(Decl).
  let #(st0, state3) = fresh_var(state2)
  let fresh_wrap = fn(rest) {
    CLet([st0], seam_call(ctx.binding.state_module, "fresh", [decl_term]), rest)
  }
  // (2) element segments, (3) data segments, (4) start — each threading the record.
  use #(elem_wraps, cur1, state4) <- result.try(threaded_elem_wrappers(
    module.elements,
    st0,
    state3,
    ctx,
  ))
  use #(data_wraps, cur2, state5) <- result.try(threaded_data_wrappers(
    module.data_segments,
    cur1,
    state4,
    ctx,
  ))
  use #(start_wraps, cur3, _state6) <- result.try(threaded_start_wrapper(
    module,
    cur2,
    state5,
    ctx,
  ))
  // Assemble: seeds → fresh → element → data → start, wrapping the returned final record.
  let all_wraps =
    list.flatten([seed_wraps, [fresh_wrap], elem_wraps, data_wraps, start_wraps])
  let body =
    list.fold_right(all_wraps, CVar(cur3), fn(rest, wrap) { wrap(rest) })
  Ok(FunDef(FName("instantiate", 0), CFun([], body)))
}

/// Turn a list of zero-result seed effects into `let <g> = <effect> in …` wrappers, each with
/// a fresh discarded binder — the `seed_fuel`/`seed_policy` lines under threaded `instantiate`.
fn discard_wrappers(
  effects: List(CExpr),
  state: EmitState,
) -> #(List(fn(CExpr) -> CExpr), EmitState) {
  list.fold(effects, #([], state), fn(acc, effect) {
    let #(wraps, st) = acc
    let #(g, st2) = fresh_var(st)
    let wrap = fn(rest) { CLet([g], effect, rest) }
    #(list.append(wraps, [wrap]), st2)
  })
}

/// Build the threaded element-segment wrappers, threading the record from `cur`. Each active
/// segment produces `let St' = case '<table>':'t_init_elem'(St, Off, Entries) of {ok,S}->S;
/// {error,E}->raise in …` and advances the current state var. Returns the wrappers (in order),
/// the final state var, and the emit state. `Error(NonConstInit)` for a non-const offset;
/// `Error(UnknownFunction)` for an undefined element target.
fn threaded_elem_wrappers(
  segs: List(ir.ElementSegment),
  cur: String,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(List(fn(CExpr) -> CExpr), String, EmitState), EmitError) {
  list.try_fold(segs, #([], cur, state), fn(acc, seg) {
    let #(wraps, cur, st) = acc
    use #(offset_expr, funcs) <- result.try(elem_active_funcs(seg))
    use offset <- result.try(const_fold(offset_expr))
    use #(entries, st2) <- result.try(build_threaded_entries(funcs, ctx, st))
    let call =
      seam_call(ctx.binding.table_module, "t_init_elem", [
        CVar(cur),
        CInt(offset),
        core_list(entries),
      ])
    let #(reduced, st3) = record_result_case(call, ctx, st2)
    let #(newvar, st4) = fresh_var(st3)
    let wrap = fn(rest) { CLet([newvar], reduced, rest) }
    Ok(#(list.append(wraps, [wrap]), newvar, st4))
  })
}

/// Build the threaded data-segment wrappers, threading the record from `cur`. Each active
/// segment produces `let St' = case '<mem>':'t_init_data'(St, Off, Bytes) of {ok,S}->S;
/// {error,E}->raise in …`. `Error(NonConstInit)` for a non-const offset.
fn threaded_data_wrappers(
  segs: List(ir.DataSegment),
  cur: String,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(List(fn(CExpr) -> CExpr), String, EmitState), EmitError) {
  list.try_fold(segs, #([], cur, state), fn(acc, seg) {
    let #(wraps, cur, st) = acc
    use offset_expr <- result.try(data_active_offset(seg))
    use offset <- result.try(const_fold(offset_expr))
    let call =
      seam_call(ctx.binding.mem_module, "t_init_data", [
        CVar(cur),
        CInt(offset),
        core_binary_bytes(seg.bytes),
      ])
    let #(reduced, st2) = record_result_case(call, ctx, st)
    let #(newvar, st3) = fresh_var(st2)
    let wrap = fn(rest) { CLet([newvar], reduced, rest) }
    Ok(#(list.append(wraps, [wrap]), newvar, st3))
  })
}

/// Build the threaded `start` wrapper (WASM `start` is `[]→[]`). A STATE-REACHING start
/// threads the record: `case apply 'f<start>'/(a+1)(St) of <{_, St'}> -> …` (the `'ok'`
/// package is discarded), advancing the current state var to `St'`. A PURE start is
/// `let _ = apply 'f<start>'/a() in …` with the record unchanged. No `start` → no wrapper.
/// `Error(UnknownFunction)` if `start` names no defined function.
fn threaded_start_wrapper(
  module: Module,
  cur: String,
  state: EmitState,
  ctx: Ctx,
) -> Result(#(List(fn(CExpr) -> CExpr), String, EmitState), EmitError) {
  case module.start {
    None -> Ok(#([], cur, state))
    Some(name) ->
      case dict.get(ctx.fn_arity, name) {
        Error(_) -> Error(UnknownFunction(name))
        Ok(arity) ->
          case set.contains(ctx.fn_state_reaching, name) {
            True -> {
              let applied = CApply(FName(name, arity + 1), [CVar(cur)])
              let #(wildvar, state2) = fresh_var(state)
              let #(newvar, state3) = fresh_var(state2)
              let wrap = fn(rest) {
                CCase(applied, [
                  CClause(
                    [PTuple([PVar(wildvar), PVar(newvar)])],
                    CAtom("true"),
                    rest,
                  ),
                ])
              }
              Ok(#([wrap], newvar, state3))
            }
            False -> {
              let applied = CApply(FName(name, arity), [])
              let #(wildvar, state2) = fresh_var(state)
              let wrap = fn(rest) { CLet([wildvar], applied, rest) }
              Ok(#([wrap], cur, state2))
            }
          }
      }
  }
}

/// Build the threaded `{TypeTag, Closure}` entry list for an element segment's `funcs`.
fn build_threaded_entries(
  funcs: List(String),
  ctx: Ctx,
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(funcs, #([], state), fn(acc, fname) {
    let #(entries, st) = acc
    use #(entry, st2) <- result.try(threaded_element_entry(fname, ctx, st))
    Ok(#(list.append(entries, [entry]), st2))
  })
}

/// One THREADED element-segment entry `{TypeTag, Closure}`: the function's IR `FuncType` (the
/// SAME `func_type_term` renderer the call site uses, so `rt_table`'s type guard matches)
/// paired with a threaded closure over the compile-time-fixed target name.
/// `Error(UnknownFunction)` if `fname` is not defined.
fn threaded_element_entry(
  fname: String,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  case dict.get(ctx.fn_sig, fname) {
    Error(_) -> Error(UnknownFunction(fname))
    Ok(sig) -> {
      let arity = result.unwrap(dict.get(ctx.fn_arity, fname), 0)
      let r = result.unwrap(dict.get(ctx.fn_results, fname), 0)
      let reaching = set.contains(ctx.fn_state_reaching, fname)
      let #(closure, state2) =
        threaded_element_closure(fname, arity, r, reaching, state)
      Ok(#(CTuple([func_type_term(sig), closure]), state2))
    }
  }
}

/// A build-controlled THREADED element-segment closure `fun(St, ArgsList) -> {ResultList, St'}`
/// matching the frozen table-entry ABI `fn(InstanceState, List(Int)) -> #(List(Int),
/// InstanceState)` (§C). Unpacks `ArgsList` to the target's static `arity`, then:
/// - PURE target: `{wrap(apply 'f'/n(args…)), St}` — thread `St` through UNTOUCHED.
/// - STATE-REACHING target: `{Pkg, St'} = apply 'f'/(n+1)(St, args…)` then `{wrap(Pkg), St'}`.
/// Always a static `apply` of a COMPILE-TIME-LITERAL name — `St` is a parameter, never a
/// dispatch key (D3a).
fn threaded_element_closure(
  fname: String,
  arity: Int,
  r: Int,
  reaching: Bool,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(stvar, state1) = fresh_var(state)
  let #(argsvar, state2) = fresh_var(state1)
  let #(argnames, state3) = fresh_n_vars(state2, arity)
  case reaching {
    False -> {
      let applied = CApply(FName(fname, arity), list.map(argnames, CVar))
      let #(wrapped, state4) = wrap_result_list(applied, r, state3)
      let paired = CTuple([wrapped, CVar(stvar)])
      let body = wrap_args_case(argsvar, arity, argnames, paired)
      #(CFun([stvar, argsvar], body), state4)
    }
    True -> {
      let applied =
        CApply(FName(fname, arity + 1), [
          CVar(stvar),
          ..list.map(argnames, CVar)
        ])
      let #(pkgvar, state4) = fresh_var(state3)
      let #(stoutvar, state5) = fresh_var(state4)
      let #(wrapped, state6) = wrap_result_list(CVar(pkgvar), r, state5)
      let paired = CTuple([wrapped, CVar(stoutvar)])
      let destructure =
        CCase(applied, [
          CClause(
            [PTuple([PVar(pkgvar), PVar(stoutvar)])],
            CAtom("true"),
            paired,
          ),
        ])
      let body = wrap_args_case(argsvar, arity, argnames, destructure)
      #(CFun([stvar, argsvar], body), state6)
    }
  }
}

/// Wrap `inner` in the args-list unpack for an element closure: `case ArgsList of <[A0,…]> ->
/// inner` (or `inner` verbatim for a 0-arity target, whose args list is the empty `[]`).
fn wrap_args_case(
  argsvar: String,
  arity: Int,
  argnames: List(String),
  inner: CExpr,
) -> CExpr {
  case arity {
    0 -> inner
    _ ->
      CCase(CVar(argsvar), [
        CClause([list_pattern(argnames)], CAtom("true"), inner),
      ])
  }
}

/// The `rt_meter:seed_fuel(binding.fuel_budget)` per-instance seed — `[seam_call…]` under
/// `MeterFuel` (arming the fail-closed CPU bound, F5), or `[]` under `MeterOff` (no `Charge`
/// sites to bound, so no seed — the F5 zero-overhead posture). `fuel_budget` is baked as a
/// Core integer literal. Emitted as `instantiate/0`'s first effect.
fn seed_fuel_effect(ctx: Ctx) -> List(CExpr) {
  case ctx.binding.meter {
    MeterFuel -> [
      seam_call(ctx.binding.meter_module, "seed_fuel", [
        CInt(ctx.binding.fuel_budget),
      ]),
    ]
    MeterOff -> []
  }
}

/// The `rt_host:seed_policy(binding.host_policy)` per-instance seed — ALWAYS emitted (F4).
/// The `host_policy` is baked as a Core Erlang literal via `host_policy_term`. A fixed
/// `host_module` call, so it adds no ambient authority (D3a).
fn seed_policy_effect(ctx: Ctx) -> List(CExpr) {
  [
    seam_call(ctx.binding.host_module, "seed_policy", [
      host_policy_term(ctx.binding.host_policy),
    ]),
  ]
}

/// Render a `HostPolicy` as the Core Erlang literal Gleam compiles it to — the term
/// `rt_host:seed_policy`/`current_policy` round-trips (rt_host §): `HostDenyAll` → the atom
/// `'host_deny_all'`, `HostOpen` → `'host_open'`, `HostWhitelist(allow)` →
/// `{'host_whitelist', [{<<Cap>>, <<Name>>}…]}` (each string a BEAM binary). Build-controlled
/// (from `binding.host_policy`) — NEVER derived from program data (D3a). Total.
fn host_policy_term(policy: HostPolicy) -> CExpr {
  case policy {
    HostDenyAll -> CAtom("host_deny_all")
    HostOpen -> CAtom("host_open")
    HostWhitelist(allow) ->
      CTuple([
        CAtom("host_whitelist"),
        core_list(
          list.map(allow, fn(pair) {
            let #(cap, name) = pair
            CTuple([core_binary_string(cap), core_binary_string(name)])
          }),
        ),
      ])
  }
}

/// Sequence a list of zero-result ordered effects into nested `let <g> = <effect> in …`,
/// ending in `'ok'`. Each `let` is strict, so every effect runs in order (non-DCE, E6); the
/// discarded binders are fresh wildcards.
fn chain_effects(
  effects: List(CExpr),
  state: EmitState,
) -> #(CExpr, EmitState) {
  case effects {
    [] -> #(CAtom("ok"), state)
    [e, ..rest] -> {
      let #(g, state2) = fresh_var(state)
      let #(tail, state3) = chain_effects(rest, state2)
      #(CLet([g], e, tail), state3)
    }
  }
}

/// Build the `StateDecl` Core TERM seed passed to `rt_state:seed` — the Gleam record
/// `StateDecl(mem, globals, table)` compiles to `{state_decl, Mem, Globals, Table}`:
/// `Mem = rt_mem:fresh(MinPages, MaxOpt, SafeCap)` (a 0-page memory when the module declares
/// none), `Table = rt_table:new(Min, MaxOpt)` (the first declared table, or an empty one),
/// `Globals = [{NameBin, InitBits}…]`. `SafeCap` is the build-time `binding.safe_max_pages`.
fn state_decl_term(
  module: Module,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  // The FIRST (index-0) memory's sizing. KEYSTONE: a single 32-bit memory emits the same
  // `rt_mem:fresh(Min, Max, Cap)` call as Phase-4 (byte-identical); the multi-memory vector
  // seed (index 1+) is P5-06/09's. `[]` (numerics-only) → a 0-page memory, unchanged.
  let #(min_pages, mem_max) = case module.memories {
    [m, ..] -> #(m.min_pages, option_int_term(m.max_pages))
    [] -> #(0, CAtom("none"))
  }
  let mem =
    seam_call(ctx.binding.mem_module, "fresh", [
      CInt(min_pages),
      mem_max,
      CInt(ctx.binding.safe_max_pages),
    ])
  let table = case module.tables {
    [t, ..] ->
      seam_call(ctx.binding.table_module, "new", [
        CInt(t.min),
        option_int_term(t.max),
      ])
    [] -> seam_call(ctx.binding.table_module, "new", [CInt(0), CAtom("none")])
  }
  use globals <- result.try(global_pairs(module.globals))
  Ok(#(CTuple([CAtom("state_decl"), mem, globals, table]), state))
}

/// The `[{NameBin, InitBits}…]` Core list of a module's globals — each `GlobalDecl.init`
/// constant-folded to a bit pattern. `Error(NonConstInit)` if any init is non-constant.
fn global_pairs(globals: List(ir.GlobalDecl)) -> Result(CExpr, EmitError) {
  use pairs <- result.try(
    list.try_map(globals, fn(g) {
      use bits <- result.try(const_fold(g.init))
      Ok(CTuple([core_binary_string(g.name), CInt(bits)]))
    }),
  )
  Ok(core_list(pairs))
}

/// Render an `Option(Int)` as a Core term — `Some(n)` → `{some, n}`, `None` → `none` (the
/// Gleam `Option` runtime shape `rt_mem.fresh` / `rt_table.new` expect for `max`).
fn option_int_term(o: Option(Int)) -> CExpr {
  case o {
    Some(n) -> CTuple([CAtom("some"), CInt(n)])
    None -> CAtom("none")
  }
}

/// Build the ordered `init_elem` effects for the active element segments. Each →
/// `case call '<table_module>':'init_elem'(Off, Entries) of {ok,_}->'ok'; {error,E}->raise`,
/// where `Entries` is a list of `{TypeTag, Closure}` (see `element_entry`). `Off` is the
/// constant-folded offset.
fn element_segment_effects(
  segs: List(ir.ElementSegment),
  ctx: Ctx,
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(segs, #([], state), fn(acc, seg) {
    let #(effects, st) = acc
    use #(offset_expr, funcs) <- result.try(elem_active_funcs(seg))
    use offset <- result.try(const_fold(offset_expr))
    use #(entries, st2) <- result.try(build_entries(funcs, ctx, st))
    let call =
      seam_call(ctx.binding.table_module, "init_elem", [
        CInt(offset),
        core_list(entries),
      ])
    let #(effect, st3) = trapping_effect(call, ctx, st2)
    Ok(#(list.append(effects, [effect]), st3))
  })
}

/// Build the `{TypeTag, Closure}` entry list for an element segment's `funcs`.
fn build_entries(
  funcs: List(String),
  ctx: Ctx,
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(funcs, #([], state), fn(acc, fname) {
    let #(entries, st) = acc
    use #(entry, st2) <- result.try(element_entry(fname, ctx, st))
    Ok(#(list.append(entries, [entry]), st2))
  })
}

/// One element-segment entry `{TypeTag, Closure}`: the function's IR `FuncType` (via the
/// SAME `func_type_term` renderer the call site uses, so `rt_table`'s guard 3 matches) paired
/// with a build-controlled closure over its compile-time-fixed module-local name (§3 —
/// the integer index is the only runtime data; the function name is a literal).
/// `Error(UnknownFunction)` if `fname` is not a defined function.
fn element_entry(
  fname: String,
  ctx: Ctx,
  state: EmitState,
) -> Result(#(CExpr, EmitState), EmitError) {
  case dict.get(ctx.fn_sig, fname) {
    Error(_) -> Error(UnknownFunction(fname))
    Ok(sig) -> {
      let arity = result.unwrap(dict.get(ctx.fn_arity, fname), 0)
      let r = result.unwrap(dict.get(ctx.fn_results, fname), 0)
      let #(closure, state2) = element_closure(fname, arity, r, state)
      Ok(#(CTuple([func_type_term(sig), closure]), state2))
    }
  }
}

/// A build-controlled element-segment closure `fun(Args) -> Results` adapting the
/// `fn(List(Int)) -> List(Int)` table-entry ABI to a static `apply 'f<idx>'/arity`: unpack
/// the args list to the function's static `arity`, apply the COMPILE-TIME-LITERAL name, then
/// re-wrap the `function_return`-packaged result back into a list (0 → `[]`, 1 → `[v]`, N →
/// `[v1…vn]`). Never a data-driven `apply` (D3a).
fn element_closure(
  fname: String,
  arity: Int,
  r: Int,
  state: EmitState,
) -> #(CExpr, EmitState) {
  let #(argsvar, state1) = fresh_var(state)
  let #(argnames, state2) = fresh_n_vars(state1, arity)
  let applied = CApply(FName(fname, arity), list.map(argnames, CVar))
  let #(wrapped, state3) = wrap_result_list(applied, r, state2)
  let body = case arity {
    0 -> wrapped
    _ ->
      CCase(CVar(argsvar), [
        CClause([list_pattern(argnames)], CAtom("true"), wrapped),
      ])
  }
  #(CFun([argsvar], body), state3)
}

/// Re-wrap a `function_return`-packaged call result into the `List(Int)` the table-entry ABI
/// returns: 0 results → `[]` (binding+discarding the dummy so the call still RUNS — its trap
/// still propagates); 1 result → `[V]`; N≥2 → destructure the `{V1,…,Vn}` tuple → `[V1,…,Vn]`.
fn wrap_result_list(
  produced: CExpr,
  r: Int,
  state: EmitState,
) -> #(CExpr, EmitState) {
  case r {
    0 -> {
      let #(g, state2) = fresh_var(state)
      #(CLet([g], produced, CNil), state2)
    }
    1 -> #(CCons(produced, CNil), state)
    _ -> {
      let #(names, state2) = fresh_n_vars(state, r)
      let clause =
        CClause(
          [PTuple(list.map(names, PVar))],
          CAtom("true"),
          core_list(list.map(names, CVar)),
        )
      #(CCase(produced, [clause]), state2)
    }
  }
}

/// Build the ordered `init_data` effects for the active data segments. Each →
/// `case call '<mem_module>':'init_data'(Off, Bytes) of {ok,_}->'ok'; {error,E}->raise`,
/// `Bytes` the segment payload as a `CBinary` literal, `Off` the constant-folded offset.
fn data_segment_effects(
  segs: List(ir.DataSegment),
  ctx: Ctx,
  state: EmitState,
) -> Result(#(List(CExpr), EmitState), EmitError) {
  list.try_fold(segs, #([], state), fn(acc, seg) {
    let #(effects, st) = acc
    use offset_expr <- result.try(data_active_offset(seg))
    use offset <- result.try(const_fold(offset_expr))
    let call =
      seam_call(ctx.binding.mem_module, "init_data", [
        CInt(offset),
        core_binary_bytes(seg.bytes),
      ])
    let #(effect, st2) = trapping_effect(call, ctx, st)
    Ok(#(list.append(effects, [effect]), st2))
  })
}

/// The `start` effect (if any): `apply 'f<idx>'/0()` — a trap inside it propagates (raises)
/// and fails instantiation. `Error(UnknownFunction)` if `start` names no defined function.
fn start_effects(module: Module, ctx: Ctx) -> Result(List(CExpr), EmitError) {
  case module.start {
    None -> Ok([])
    Some(name) ->
      case dict.get(ctx.fn_arity, name) {
        Error(_) -> Error(UnknownFunction(name))
        Ok(arity) -> Ok([CApply(FName(name, arity), [])])
      }
  }
}

/// Constant-fold a Phase-2 constant-literal init/offset `Expr` (`Values([Const])`) to its
/// raw bit-pattern `Int`. `Error(NonConstInit)` for any non-constant shape (e.g. an
/// imported-global `GlobalGet`, an extended-const chain, or a multi-value form) — fail-
/// closed, never a panic, never arbitrary emitted code in the seed decl.
fn const_fold(expr: Expr) -> Result(Int, EmitError) {
  case expr {
    Values([v]) -> const_value_bits(v)
    _ -> Error(NonConstInit("non-constant init/offset expression"))
  }
}

/// The raw bit pattern of a constant `Value`; `Error(NonConstInit)` for a `Var` (a
/// non-constant operand).
fn const_value_bits(v: Value) -> Result(Int, EmitError) {
  case v {
    ConstI32(b) | ConstI64(b) | ConstF32(b) | ConstF64(b) -> Ok(b)
    Var(_) -> Error(NonConstInit("variable in constant init/offset"))
    // A reference-typed constant init (`ref.null`) has no numeric bit pattern; its seeding is
    // P5-06/09's (a `ConstNull` never appears in a Phase-1..4 numeric offset/init).
    ir.ConstNull(_) ->
      Error(NonConstInit("null reference in constant init/offset"))
  }
}

/// Extract the Phase-2 active-funcref parts of an element segment for the keystone codegen
/// path: the target-table offset expression + the funcref function names. Returns
/// `Error(UnsupportedNode(_))` for a passive/declarative segment, an `externref` segment, or a
/// non-`RefFunc` init item (their real lowering is P5-06/07). No Phase-1..4 module has one, so
/// the active-funcref path is byte-identical and the error paths are never reached.
fn elem_active_funcs(
  seg: ir.ElementSegment,
) -> Result(#(Expr, List(String)), EmitError) {
  case seg.mode, seg.ref_ty {
    ir.ElemActive(_table, offset), ir.FuncRef -> {
      use funcs <- result.try(
        list.try_map(seg.init, fn(item) {
          case item {
            ir.RefFunc(name) -> Ok(name)
            _ -> Error(UnsupportedNode("elem_item"))
          }
        }),
      )
      Ok(#(offset, funcs))
    }
    _, _ -> Error(UnsupportedNode("elem_segment"))
  }
}

/// Extract the Phase-2 active-at-memory-0 offset of a data segment. Returns
/// `Error(UnsupportedNode(_))` for a passive segment or an active-at-mem>0 segment (their
/// lowering is P5-06/08). No Phase-1..4 module has one, so the active-at-0 path is byte-
/// identical and the error paths are never reached.
fn data_active_offset(seg: ir.DataSegment) -> Result(Expr, EmitError) {
  case seg.mode {
    ir.DataActive(0, offset) -> Ok(offset)
    ir.DataActive(_, _) -> Error(UnsupportedNode("data_segment_mem"))
    ir.DataPassive -> Error(UnsupportedNode("data_passive"))
  }
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
    // Phase-2 float NumOps (`«RTNUM2-SIG-FROZEN»`) — all TOTAL (stay out of `is_trapping`).
    // Unary/copysign produce the width's float bits; the 6 comparisons produce an i32 0/1.
    FAbs(f) -> fw(f) <> "_abs"
    FNeg(f) -> fw(f) <> "_neg"
    FCeil(f) -> fw(f) <> "_ceil"
    FFloor(f) -> fw(f) <> "_floor"
    FTrunc(f) -> fw(f) <> "_trunc"
    FNearest(f) -> fw(f) <> "_nearest"
    FSqrt(f) -> fw(f) <> "_sqrt"
    FCopysign(f) -> fw(f) <> "_copysign"
    FEq(f) -> fw(f) <> "_eq"
    FNe(f) -> fw(f) <> "_ne"
    FLt(f) -> fw(f) <> "_lt"
    FGt(f) -> fw(f) <> "_gt"
    FLe(f) -> fw(f) <> "_le"
    FGe(f) -> fw(f) <> "_ge"
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
    // Phase-2 ConvOps (`«RTNUM2-SIG-FROZEN»`). TRAPPING float→int truncation
    // (`i{to}_trunc_f{from}_{s,u}`) — `emit_convert` routes these through the
    // `case`-and-`raise` shape (see `is_trapping_conv`), NOT a bare call.
    TruncS(from, to) -> Ok(iw(to) <> "_trunc_f" <> fwn(from) <> "_s")
    TruncU(from, to) -> Ok(iw(to) <> "_trunc_f" <> fwn(from) <> "_u")
    // int→float conversion + float width change — all TOTAL (bare call, never trap).
    ConvertS(from, to) -> Ok(fw(to) <> "_convert_" <> iw(from) <> "_s")
    ConvertU(from, to) -> Ok(fw(to) <> "_convert_" <> iw(from) <> "_u")
    F32DemoteF64 -> Ok("f32_demote_f64")
    F64PromoteF32 -> Ok("f64_promote_f32")
  }
}

/// `True` for the TRAPPING float→int truncations (`TruncS`/`TruncU`) — those return
/// `Result(Int, TrapReason)` (trap `InvalidConversionToInteger` on NaN/±Inf,
/// `IntOverflow` out of range) and need the `case`-and-`raise` lowering. Every other
/// `ConvOp` is total (a bare `call`). Getting this wrong either drops a mandated trap or
/// wraps a total op in a spurious `case` (unit-10 grounded fact).
fn is_trapping_conv(op: ConvOp) -> Bool {
  case op {
    TruncS(_, _) | TruncU(_, _) -> True
    _ -> False
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
    InvalidConversionToInteger -> "InvalidConversionToInteger"
    UndefinedElement -> "UndefinedElement"
    UninitializedElement -> "UninitializedElement"
    TableOutOfBounds -> "TableOutOfBounds"
    // Runtime-only policy reason (F5); never emitted by lowering, but the match is exhaustive.
    FuelExhausted -> "FuelExhausted"
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
    MemSize(_) -> acc
    MemGrow(_, delta) -> collect_value(delta, acc)
    MemLoad(_, _, addr, _, _) -> collect_value(addr, acc)
    MemStore(_, _, addr, value, _) ->
      collect_value(value, collect_value(addr, acc))
    // ── Phase-5 reference/table/bulk nodes: collect the `Var` names in their operands so
    // gensym avoids them (over-approximating is safe). ──
    ir.RefFunc(_) -> acc
    ir.RefIsNull(arg) -> collect_value(arg, acc)
    ir.TableGet(_, index) -> collect_value(index, acc)
    ir.TableSet(_, index, value) ->
      collect_value(value, collect_value(index, acc))
    ir.TableSize(_) -> acc
    ir.TableGrow(_, delta, init) ->
      collect_value(init, collect_value(delta, acc))
    ir.TableFill(_, offset, value, count) ->
      collect_value(count, collect_value(value, collect_value(offset, acc)))
    ir.TableInit(_, _, dst, src, count) ->
      collect_value(count, collect_value(src, collect_value(dst, acc)))
    ir.TableCopy(_, _, dst, src, count) ->
      collect_value(count, collect_value(src, collect_value(dst, acc)))
    ir.ElemDrop(_) -> acc
    ir.MemFill(_, dest, value, count) ->
      collect_value(count, collect_value(value, collect_value(dest, acc)))
    ir.MemCopy(_, _, dst, src, count) ->
      collect_value(count, collect_value(src, collect_value(dst, acc)))
    ir.MemInit(_, _, dst, src, count) ->
      collect_value(count, collect_value(src, collect_value(dst, acc)))
    ir.DataDrop(_) -> acc
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
