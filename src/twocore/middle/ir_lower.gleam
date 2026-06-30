//// Unit 11a — `ir_lower` — the one middle-end POLICY pass (high-level §4 `M3`, §6).
////
//// `lower/2` is an IR→IR transform that runs *after* the frontend lowering (`lower.gleam`,
//// unit 10) and *before* the backend (`emit_core`, unit 08). It is the build-time
//// capability/stdlib/metering pass — the **only** middle-end pass Phase 1 ships. For a
//// `Safe` binding it does three things, all build-time, all fail-closed (D4/D9):
////
////   1. **`call_host` capability gate (fail-closed).** It classifies every `CallHost`:
////      - a call into the reserved `own`-stdlib capability (`"std"`) is *resolved* against
////        the Phase-1 stdlib surface and its concrete `module:fn/arity` target is gated
////        through the `rt_bif` allowlist. An unknown stdlib name → `UnknownStdlibFn`; a
////        resolved target not on the allowlist (including a wrong arity) → `BifNotAllowed`.
////      - a call to a **declared host import** (a `(capability, name)` present in
////        `module.imports`) is **left unchanged** — it is rejected at RUN time by the
////        deny-all host (`rt_host`), so the capability boundary is exercised end-to-end,
////        not short-circuited at build time (overview pitfall #3).
////      - a call to anything else — an un-allowlisted capability that is neither the
////        stdlib capability nor a declared import — is **rejected here**, fail-closed
////        (`ForbiddenHost`).
////      `CallHost` nodes are not rewritten: the mechanical stdlib-vs-host routing is
////      `emit_core`'s `resolve_stdlib`/`call_host` split (unit 08). This pass is the
////      POLICY gate that decides which calls are *permitted* to reach that router; the
////      two share the same pinned `("std","gcd") → rt_stdlib:gcd/2` triple (state.md),
////      cross-checked against `rt_bif` by a test so they cannot drift.
////
////   2. **Metering insertion (the non-negotiable seam — D9).** Every function body is
////      wrapped in `Charge(fn_cost, body)`, and every `Loop` body in
////      `Charge(loop_cost, body)`, so the metering hook is exercised end-to-end and never
////      has to be retrofitted into codegen later. The cost *values* are a minimal fixed
////      model (their magnitude is irrelevant; the node's presence is the point). `Charge`
////      lowers (unit 08) to `let _ = rt_meter:charge(c) in body`, which neither changes
////      results nor moves a loop back-edge out of tail position — so the constant-space
////      loop property is preserved with metering on.
////
//// This module reads `ir.gleam`, the `Binding` type, and the build-time `rt_bif` gate
//// ONLY. It does **not** import the runtime IMPL modules (`rt_trap`/`rt_host`/`rt_meter`/
//// `rt_stdlib`) — they are called by *generated* code at run time, never by this pass
//// (D3a). `rt_bif` is build-time policy data, designed to be consulted here.

import gleam/list
import gleam/set.{type Set}
import twocore/ir.{type Expr, type Function, type Module, type Value}
import twocore/runtime/instance.{type Binding, Safe, Unsafe}
import twocore/runtime/rt_bif

// ─────────────────────────────── policy data (build-time) ───────────────────────────────

/// The reserved capability string that names the `own` standard library (high-level §6).
/// A `CallHost` whose capability equals this is a stdlib call and MUST resolve against the
/// stdlib surface (or be rejected); every other capability is a (potential) host import.
/// Pinned with unit 09 / state.md.
pub const stdlib_capability: String = "std"

/// The minimal cost charged once on entry to every function body. The value is arbitrary
/// (D9 — only the metering *seam* matters in Phase 1); kept at `1` so the running fuel
/// total is a readable lower bound on the number of `Charge` sites executed.
pub const fn_cost: Int = 1

/// The minimal cost charged once per `Loop` iteration (re-entry of the loop head). As with
/// `fn_cost` the value is arbitrary; `1` makes fuel grow by exactly one per iteration so a
/// test can assert metering is proportional to loop work.
pub const loop_cost: Int = 1

/// The Phase-1 `own`-stdlib surface: each `#(ir_name, beam_fn, arity)` maps the *name* used
/// in an IR `CallHost(stdlib_capability, ir_name, _)` to the `rt_stdlib` function and arity
/// it resolves to.
///
/// Phase 1 ships exactly one vetted entry, `gcd/2` (state.md). The concrete BEAM module of a
/// resolved target is taken from `binding.stdlib_module` (not hard-coded here), and the
/// resolved `module:fn/arity` is then gated through `rt_bif.allowlist()` — so this surface
/// and the `rt_bif` allowlist cannot disagree without a cross-check test failing.
fn own_stdlib_surface() -> List(#(String, String, Int)) {
  [#("gcd", "gcd", 2)]
}

// ─────────────────────────────── error type (D4) ───────────────────────────────

/// Every reason `lower` rejects a module (this pass's OWN error type — D4, there is no
/// shared `StageError`). `lower` is **total**: a policy violation returns `Error`, never a
/// `panic`/`let assert`.
///
/// - `UnknownStdlibFn(capability, name)`: a `CallHost` into the reserved stdlib capability
///   named a function absent from the `own` surface. Fail-closed.
/// - `BifNotAllowed(name)`: a resolved stdlib `CallHost` would reach a concrete BEAM target
///   not on the `rt_bif` allowlist (e.g. a wrong arity, or a binding whose `stdlib_module`
///   is not the vetted one). Fail-closed.
/// - `ForbiddenHost(capability, name)`: a `CallHost` to a capability that is neither the
///   stdlib capability nor a declared host import in `module.imports` — an un-allowlisted
///   capability with no provenance. Rejected here, fail-closed (a *declared* host import is
///   NOT rejected here; it is denied at run time by `rt_host`).
pub type LowerError {
  UnknownStdlibFn(capability: String, name: String)
  BifNotAllowed(name: String)
  ForbiddenHost(capability: String, name: String)
}

// ─────────────────────────────── entry point ───────────────────────────────

/// Apply the Safe-mode capability/stdlib/metering policy to `module`, returning the
/// rewritten module or the FIRST policy violation.
///
/// - `module`: the IR module produced by the frontend lowering (unit 10). Its functions'
///   bodies are walked; `globals`/`imports`/`exports`/`data_segments` are unchanged
///   (Phase-1 globals carry only constant initialisers and contain no `CallHost`/`Loop`).
/// - `binding`: the build-time runtime binding. Only `binding.mode` and
///   `binding.stdlib_module` are read here; the impl module *bodies* are never imported.
///
/// Behaviour by mode:
/// - `Safe`: runs the full pass — gates every `CallHost` (see `LowerError`) and inserts the
///   `Charge` metering effect at every function body and loop body.
/// - `Unsafe` (Phase 2, not shipped): returns `module` unchanged. There is no way to obtain
///   an `Unsafe` binding from the Phase-1 `profiles` (fail-closed), so this branch is a
///   forward-compatible placeholder, never reached by the Phase-1 pipeline.
///
/// Returns `Ok(rewritten_module)` if every `CallHost` is permitted, or `Error(LowerError)`
/// on the first violation (fail-closed). Total — never panics on any input IR.
pub fn lower(module: Module, binding: Binding) -> Result(Module, LowerError) {
  case binding.mode {
    Unsafe -> Ok(module)
    Safe -> {
      let imports = import_set(module)
      case
        list.try_map(module.functions, fn(f) {
          lower_function(f, binding, imports)
        })
      {
        Error(e) -> Error(e)
        Ok(fns) -> Ok(ir.Module(..module, functions: fns))
      }
    }
  }
}

// ─────────────────────────────── per-function ───────────────────────────────

/// Lower one function: gate every `CallHost` in its body and meter loop bodies, then wrap
/// the whole (rewritten) body in a `Charge(fn_cost, _)` so each call to the function meters
/// once on entry. Returns the rewritten `Function` or the first policy violation.
fn lower_function(
  f: Function,
  binding: Binding,
  imports: Set(#(String, String)),
) -> Result(Function, LowerError) {
  case lower_expr(f.body, binding, imports) {
    Error(e) -> Error(e)
    Ok(body) -> Ok(ir.Function(..f, body: ir.Charge(fn_cost, body)))
  }
}

/// Recursively walk an expression: validate every nested `CallHost` against the policy and
/// wrap every `Loop` body in `Charge(loop_cost, _)`. Pure/leaf and control-transfer nodes
/// are returned unchanged. Total; returns the first policy violation as `Error`.
fn lower_expr(
  expr: Expr,
  binding: Binding,
  imports: Set(#(String, String)),
) -> Result(Expr, LowerError) {
  case expr {
    // leaves / pure ops — nothing to gate or meter
    ir.Values(_)
    | ir.Num(_, _)
    | ir.Convert(_, _)
    | ir.TermOp(_, _)
    | ir.MemSize
    | ir.MemGrow(_)
    | ir.MemLoad(_, _, _, _)
    | ir.MemStore(_, _, _, _)
    | ir.GlobalGet(_)
    | ir.GlobalSet(_, _)
    | ir.CallDirect(_, _)
    | ir.CallIndirect(_, _, _, _)
    | ir.Break(_, _)
    | ir.Continue(_, _)
    | ir.Return(_)
    | ir.Trap(_) -> Ok(expr)

    // THE capability boundary — gate it; the node is left unchanged for `emit_core` to route
    ir.CallHost(cap, name, args) ->
      case classify_call_host(cap, name, args, binding, imports) {
        Error(e) -> Error(e)
        Ok(Nil) -> Ok(expr)
      }

    // sequencing / structured control — recurse into sub-expressions
    ir.Let(names, rhs, body) ->
      case lower_expr(rhs, binding, imports) {
        Error(e) -> Error(e)
        Ok(rhs2) ->
          case lower_expr(body, binding, imports) {
            Error(e) -> Error(e)
            Ok(body2) -> Ok(ir.Let(names, rhs2, body2))
          }
      }

    ir.Block(label, result, body) ->
      case lower_expr(body, binding, imports) {
        Error(e) -> Error(e)
        Ok(body2) -> Ok(ir.Block(label, result, body2))
      }

    // a loop body is metered once per iteration: wrap the rewritten body in `Charge`
    ir.Loop(label, params, result, body) ->
      case lower_expr(body, binding, imports) {
        Error(e) -> Error(e)
        Ok(body2) ->
          Ok(ir.Loop(label, params, result, ir.Charge(loop_cost, body2)))
      }

    ir.If(cond, result, then_branch, else_branch) ->
      case lower_expr(then_branch, binding, imports) {
        Error(e) -> Error(e)
        Ok(then2) ->
          case lower_expr(else_branch, binding, imports) {
            Error(e) -> Error(e)
            Ok(else2) -> Ok(ir.If(cond, result, then2, else2))
          }
      }

    ir.Switch(selector, result, arms, default) ->
      case
        list.try_map(arms, fn(arm) {
          case lower_expr(arm.body, binding, imports) {
            Error(e) -> Error(e)
            Ok(b) -> Ok(ir.SwitchArm(arm.match, b))
          }
        })
      {
        Error(e) -> Error(e)
        Ok(arms2) ->
          case lower_expr(default, binding, imports) {
            Error(e) -> Error(e)
            Ok(default2) -> Ok(ir.Switch(selector, result, arms2, default2))
          }
      }

    // already-metered subtree (idempotent — not expected pre-lowering, but kept total)
    ir.Charge(cost, body) ->
      case lower_expr(body, binding, imports) {
        Error(e) -> Error(e)
        Ok(body2) -> Ok(ir.Charge(cost, body2))
      }
  }
}

// ─────────────────────────────── the capability gate ───────────────────────────────

/// Decide whether a single `CallHost(capability, name, args)` is PERMITTED under the Safe
/// policy. Returns `Ok(Nil)` if it may stand (the node is left unchanged for `emit_core` to
/// route), or the typed `LowerError` on a violation. See `LowerError` for the three cases.
fn classify_call_host(
  capability: String,
  name: String,
  args: List(Value),
  binding: Binding,
  imports: Set(#(String, String)),
) -> Result(Nil, LowerError) {
  case capability == stdlib_capability {
    // reserved stdlib capability → must resolve against the surface AND pass `rt_bif`
    True ->
      case resolve_stdlib_fn(name) {
        Error(_) -> Error(UnknownStdlibFn(capability, name))
        Ok(fn_name) -> {
          let target =
            rt_bif.BifTarget(
              module: binding.stdlib_module,
              function: fn_name,
              arity: list.length(args),
            )
          case rt_bif.check(target) {
            Ok(Nil) -> Ok(Nil)
            Error(_) -> Error(BifNotAllowed(name))
          }
        }
      }
    // any other capability → a declared host import is allowed (run-time deny); else reject
    False ->
      case set.contains(imports, #(capability, name)) {
        True -> Ok(Nil)
        False -> Error(ForbiddenHost(capability, name))
      }
  }
}

/// Resolve a stdlib `name` to its `rt_stdlib` function name, or `Error(Nil)` if `name` is
/// not on the `own` surface. Phase 1: only `gcd`. The surface arity is NOT used to gate the
/// call — the actual emitted arity (`list.length(args)`) is, so an arity mismatch is caught
/// by `rt_bif` rather than silently accepted.
fn resolve_stdlib_fn(name: String) -> Result(String, Nil) {
  case list.find(own_stdlib_surface(), fn(e) { e.0 == name }) {
    Ok(#(_ir_name, fn_name, _arity)) -> Ok(fn_name)
    Error(_) -> Error(Nil)
  }
}

/// The set of `(capability, name)` pairs the module DECLARES as host imports. A `CallHost`
/// to a non-stdlib capability is permitted to stand (and be denied at run time) only if its
/// `(capability, name)` is in this set; otherwise it is rejected fail-closed.
fn import_set(module: Module) -> Set(#(String, String)) {
  list.fold(module.imports, set.new(), fn(acc, imp) {
    case imp {
      ir.ImportFn(capability, name, _ty) -> set.insert(acc, #(capability, name))
    }
  })
}

// ─────────────────────────────── audit / cross-check support ───────────────────────────────

/// The concrete `rt_bif` targets this pass would resolve its `own`-stdlib surface to, under
/// `binding`. Exposed for the anti-drift cross-check test (overview §11a): it must equal the
/// `rt_bif.allowlist()` set, so the stdlib surface here and the allowlist in unit 09 cannot
/// silently diverge. Total.
pub fn resolved_stdlib_targets(binding: Binding) -> List(rt_bif.BifTarget) {
  list.map(own_stdlib_surface(), fn(entry) {
    let #(_ir_name, fn_name, arity) = entry
    rt_bif.BifTarget(module: binding.stdlib_module, function: fn_name, arity:)
  })
}
