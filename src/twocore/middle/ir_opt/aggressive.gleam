//// `middle/ir_opt/aggressive` — the Unsafe-only optimizer passes (Phase-3 unit 04, F1/F2/F4).
////
//// These passes run ONLY at `OptLevel.Aggressive`, which is reachable ONLY from
//// `profiles.unsafe()` (F4) — the Safe default (`Baseline`) never executes a line of this
//// module. Each pass carries an EXPLICIT, documented trust assumption and is proven not to
//// change a returned value (bit-for-bit, D7) or a trap (reason + trap-or-not) on any input
//// (F2). Unsafe is NOT a licence to break WebAssembly semantics: WASM has no C-style undefined
//// behaviour, so every ill-defined operation traps and inlining never drops a trap. The trust
//// here is confined to the fuel-metering POLICY overlay (`MeterOff`) and toolchain
//// well-formedness — never to WASM value/trap behaviour.
////
//// ## The profile coupling (Aggressive ⟹ MeterOff)
////
//// Both passes are sound only because `OptLevel = Aggressive` implies `MeterMode = MeterOff`
//// (only `Baseline`/`OptNone` may pair with `MeterFuel`, pinned by a keystone test). A legal
//// Aggressive build is therefore always `MeterOff`, so it carries NO `Charge` nodes and no
//// seeded fuel budget: inlining cannot perturb a fuel observable and `Charge`-elision cannot
//// drop a `FuelExhausted` trap. On real pipeline input `charge_elide` is a defence-in-depth
//// no-op; it exists so the Aggressive POSTCONDITION (output contains no `Charge`) holds
//// structurally even for hand-written `.ir` fed straight to `optimize(_, Aggressive)`.
////
//// ## Import hygiene (no cycle)
////
//// This module imports the `Pass` machinery from `middle/ir_opt/pass` (a leaf importing `ir`
//// only), NOT from `middle/ir_opt` — `ir_opt` imports THIS module to register the Aggressive
//// arm, so importing it back would cycle. The edges `aggressive → {ir, pass}` are acyclic. It
//// never imports a `runtime/*` impl module (D3a — this is a build-time IR→IR pass).
////
//// ## Honest scope (F8)
////
//// What is deliberately NOT here: LICM (needs a richer aliasing model), range-based
//// bounds-check elimination (a wrong range proof would drop a `MemoryOutOfBounds` trap), SIMD
//// vectorisation (no SIMD IR), and pure-call CSE / compile-time call evaluation (needs a
//// partial evaluator). Post-inlining copy-prop/const-fold/DCE are NOT new passes — the
//// `run_pipeline` fixpoint re-runs the whole arm (baseline included) over the enlarged bodies,
//// so inlining's newly-exposed constants are folded by unit 03's passes for free.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import gleam/string
import twocore/ir
import twocore/middle/ir_opt/pass.{type Pass, map_expr, pass, per_expr}

/// The maximum callee body size (Expr-node count) eligible for inlining at a non-unique call
/// site. Bodies larger than this are inlined ONLY when single-call-site (inline-and-delete is
/// size-neutral). A knob, not a correctness bound — termination rests on the acyclic-callee
/// guard + the size budget, not on this number.
const small_body_nodes: Int = 24

/// The ordered Unsafe-only passes, appended after the baseline passes to build the `Aggressive`
/// pipeline arm: `pipeline(Aggressive) == baseline.baseline_passes() ++ aggressive_passes()`.
///
/// Order: `[charge_elide(), inline()]`. `charge_elide` first normalises away any metering
/// instrumentation (belt-and-suspenders — §C), so inlining and the fixpoint's baseline sweep
/// see `Charge`-free bodies. Post-inlining cleanup is delivered by the `run_pipeline` fixpoint
/// re-running unit 03's baseline passes over the enlarged bodies, so no separate cleanup pass
/// appears here.
///
/// - Return: the two `Pass` values in fixed order. Total — never fails.
pub fn aggressive_passes() -> List(Pass) {
  [charge_elide(), inline()]
}

// ─────────────────────────── Pass 2 — Charge-elision ───────────────────────────

/// Elide every `Charge(cost, body)` node, rewriting it to `body` (bottom-up via `map_expr`, so
/// nested charges collapse). Implemented as `per_expr("charge-elide", …)`.
///
/// TRUST ASSUMPTION (documented, F2/F3): `binding.meter == MeterOff`. Under `MeterOff` no fuel
/// budget is ever seeded (unit 05), so `rt_meter.charge` neither raises `FuelExhausted` nor
/// participates in any observable — `fuel_consumed()` is not a contract of the Unsafe profile.
/// Removing the node therefore changes NO returned value and NO trap. This is sound ONLY under
/// the profile coupling `Aggressive ⟹ MeterOff` (see module docs) — NOT independent of
/// provenance: under Safe (`MeterFuel`) the identical elision would drop the `Charge` sites
/// whose exhaustion raises `FuelExhausted`, which is forbidden by F2. A legal Aggressive build
/// carries no `Charge` nodes at all, so on real pipeline input this pass is a no-op; it runs as
/// defence-in-depth so the Aggressive postcondition ("output contains no `Charge`") holds
/// structurally even for hand-written input.
///
/// - Return: a `Pass` that deletes every `Charge` node from every function body. Total.
pub fn charge_elide() -> Pass {
  per_expr("charge-elide", fn(e) {
    case e {
      ir.Charge(_cost, body) -> body
      other -> other
    }
  })
}

// ─────────────────────────── Pass 1 — function inlining ───────────────────────────

/// Inline eligible `CallDirect` sites (§B.1) with a capture-avoiding copy of the callee body,
/// then delete any callee left with zero remaining call sites and no export/entry reference.
///
/// A `Let(names, CallDirect(f, args), cont)` is inlined iff `f` is (1) a DEFINED function of this
/// module, (2) NON-recursive (not self-calling and not on a `CallDirect` call-graph cycle),
/// (3) leaf OR small-body (≤ `small_body_nodes`) OR called from exactly one site module-wide,
/// and (4) the running size budget can afford the callee body. The transform is
/// capture-avoiding: every callee-bound name (locals/`Let`/`Block`/`Loop` labels + loop-param
/// names) is alpha-renamed to a fresh unique name, params are substituted with the atomic ANF
/// `Value` args (no effect duplication/reorder), and the body is wrapped in a fresh
/// `Block(exit_label, f.result, …)` with every callee `Return(vs)` rewritten to
/// `Break(exit_label, vs)` (single-exit — the `Return` yields to the inlined region, not the
/// caller).
///
/// TRUST ASSUMPTION (documented, F2): `binding.meter == MeterOff` — NO `Charge` nodes present
/// (guaranteed by the `Aggressive ⟹ MeterOff` coupling), so inlining perturbs no fuel
/// observable. The pass ALSO assumes toolchain well-formedness (the callee body faithfully
/// implements `f`; names unique per-function). It never inspects or depends on WASM value/trap
/// semantics, which it preserves exactly: args are pre-evaluated `Value`s so substitution adds
/// no evaluation; the body is transplanted verbatim (only renamed) so every effect and trap
/// fires at the same point in the same order; no trap (`IntDivByZero`/`IntOverflow`/
/// `MemoryOutOfBounds`/`Unreachable`/…) is ever elided.
///
/// TERMINATION: the well-founded measure is the remaining size budget `B_remaining` — a
/// non-negative integer decremented by ≥ 1 per inline (a callee body is ≥ 1 node), bounded
/// below by 0 — plus the acyclic-callee guard (no callee is ever re-entered). When the budget is
/// spent or no site is eligible, `run` is the identity, so the `run_pipeline` fixpoint
/// converges. No `let assert`/`panic`: an ineligible/malformed shape is left unchanged (D4).
///
/// - Return: the whole-module inlining `Pass`. Total — never fails.
pub fn inline() -> Pass {
  pass("inline", run_inline)
}

/// Threaded state for one `run_inline` invocation: the remaining size budget and the next fresh
/// alpha-rename counter.
///
/// - `budget`: `B_remaining` — the number of Expr-nodes inlining may still ADD across the whole
///   module. Strictly decreases per inline; when it drops below the next callee's cost the site
///   is left unchanged (the termination measure).
/// - `counter`: the next unused integer suffix for a fresh `…$inl<n>` name. Monotonically
///   increasing so every generated name is unique.
type InlineState {
  InlineState(budget: Int, counter: Int)
}

/// The per-`run` resolution context: the callee lookup, the recursion set, and the module-wide
/// `CallDirect` site counts. Computed once from the input module, before the walk.
///
/// - `by_name`: every defined function keyed by name (the callee resolver).
/// - `recursive`: the names of functions that are self-recursive or on a `CallDirect` cycle —
///   never eligible for inlining (the acyclic guard).
/// - `sites`: `fn_name -> number of CallDirect sites` in the input module (the single-call-site
///   heuristic input).
type InlineCtx {
  InlineCtx(
    by_name: Dict(String, ir.Function),
    recursive: Set(String),
    sites: Dict(String, Int),
  )
}

/// The whole-module inlining transform: resolve the callee graph, walk every body inlining
/// eligible sites within the budget, then drop callees orphaned by the inlining.
///
/// - `module`: the IR module to rewrite.
/// - Return: `module` with eligible `CallDirect` sites inlined and orphaned non-exported callees
///   removed. Total — never fails; ineligible or malformed shapes are left unchanged.
fn run_inline(module: ir.Module) -> ir.Module {
  let funcs = module.functions
  let by_name = dict.from_list(list.map(funcs, fn(f) { #(f.name, f) }))
  let graph = build_call_graph(funcs, by_name)
  let recursive = recursive_names(funcs, graph)
  let input_sites = count_calls_module(funcs)
  let ctx =
    InlineCtx(by_name: by_name, recursive: recursive, sites: input_sites)
  // Budget: a generous allowance proportional to the module size (a safety valve; on the
  // corpus it is never exhausted). Counter: seeded ABOVE every `$inl` suffix already present so
  // generated names are globally unique across fixpoint rounds.
  let budget = 8 * module_node_count(funcs) + 4096
  let seed = 1 + max_inl_counter_module(funcs)
  let st0 = InlineState(budget: budget, counter: seed)

  let #(new_funcs_rev, _final) =
    list.fold(funcs, #([], st0), fn(acc, f) {
      let #(done, st) = acc
      let #(body2, st2) = go(f.body, ctx, st)
      #([ir.Function(..f, body: body2), ..done], st2)
    })
  let new_funcs = list.reverse(new_funcs_rev)

  // Orphan deletion: a function called in the input but no longer called in the output, that is
  // not exported / the start / referenced by an element segment, is dead — remove it.
  let output_sites = count_calls_module(new_funcs)
  let protected = protected_names(module)
  let kept =
    list.filter(new_funcs, fn(f) {
      keep_function(f.name, input_sites, output_sites, protected)
    })
  ir.Module(..module, functions: kept)
}

/// Walk one expression top-down, threading the budget/counter state and inlining eligible
/// `Let(_, CallDirect, _)` sites. Recurses INTO each inlined body so calls-of-calls are also
/// expanded within the same `run` (full acyclic expansion, bounded by the budget).
///
/// - `e`: the expression to rewrite.
/// - `ctx`: the resolution context.
/// - `st`: the threaded state on entry.
/// - Return: `#(rewritten_expr, state_after)`. Total.
fn go(e: ir.Expr, ctx: InlineCtx, st: InlineState) -> #(ir.Expr, InlineState) {
  case e {
    // the inline trigger — a call bound by a `Let`
    ir.Let(names, ir.CallDirect(fname, args), cont) ->
      case try_inline(names, fname, args, cont, ctx, st) {
        Ok(res) -> res
        Error(Nil) -> {
          let #(cont2, st2) = go(cont, ctx, st)
          #(ir.Let(names, ir.CallDirect(fname, args), cont2), st2)
        }
      }
    ir.Let(names, rhs, cont) -> {
      let #(rhs2, st1) = go(rhs, ctx, st)
      let #(cont2, st2) = go(cont, ctx, st1)
      #(ir.Let(names, rhs2, cont2), st2)
    }
    ir.Block(label, result, body) -> {
      let #(b2, st1) = go(body, ctx, st)
      #(ir.Block(label, result, b2), st1)
    }
    ir.Loop(label, params, result, body) -> {
      let #(b2, st1) = go(body, ctx, st)
      #(ir.Loop(label, params, result, b2), st1)
    }
    ir.If(cond, result, then_branch, else_branch) -> {
      let #(t2, st1) = go(then_branch, ctx, st)
      let #(e2, st2) = go(else_branch, ctx, st1)
      #(ir.If(cond, result, t2, e2), st2)
    }
    ir.Switch(sel, result, arms, default) -> {
      let #(arms_rev, st1) =
        list.fold(arms, #([], st), fn(acc, arm) {
          let #(done, s) = acc
          let #(b2, s2) = go(arm.body, ctx, s)
          #([ir.SwitchArm(..arm, body: b2), ..done], s2)
        })
      let #(def2, st2) = go(default, ctx, st1)
      #(ir.Switch(sel, result, list.reverse(arms_rev), def2), st2)
    }
    ir.Charge(cost, body) -> {
      let #(b2, st1) = go(body, ctx, st)
      #(ir.Charge(cost, b2), st1)
    }
    // leaves — no sub-expression to descend into.
    _ -> #(e, st)
  }
}

/// Attempt to inline `Let(names, CallDirect(fname, args), cont)`. Returns `Ok(#(expr, state))`
/// with the fully-processed replacement (the inlined block, itself walked for nested calls,
/// followed by the walked `cont`), or `Error(Nil)` when the site is ineligible, mis-arity, or
/// unaffordable — the caller then leaves the call unchanged (fail-safe, D4).
fn try_inline(
  names: List(String),
  fname: String,
  args: List(ir.Value),
  cont: ir.Expr,
  ctx: InlineCtx,
  st: InlineState,
) -> Result(#(ir.Expr, InlineState), Nil) {
  case eligible(fname, ctx) {
    False -> Error(Nil)
    True ->
      case dict.get(ctx.by_name, fname) {
        Error(Nil) -> Error(Nil)
        Ok(f) -> {
          let arity_ok =
            list.length(names) == list.length(f.result)
            && list.length(args) == list.length(f.params)
          case arity_ok {
            False -> Error(Nil)
            True -> {
              let cost = node_count(f.body)
              case st.budget >= cost {
                False -> Error(Nil)
                True -> {
                  let st_b = InlineState(..st, budget: st.budget - cost)
                  let #(block, st1) = build_inline(f, args, st_b)
                  let #(block2, st2) = go(block, ctx, st1)
                  let #(cont2, st3) = go(cont, ctx, st2)
                  Ok(#(ir.Let(names, block2, cont2), st3))
                }
              }
            }
          }
        }
      }
  }
}

/// Build the capture-avoiding, single-exit inlined block for a call to `f` with `args`.
///
/// Alpha-renames every callee-bound name to a fresh `…$inl<n>` name, substitutes each param with
/// its atomic `Value` arg, rewrites every `Return(vs)` to `Break(exit_label, vs)`, and wraps the
/// result in `Block(exit_label, f.result, …)`. The counter in `st` is advanced past every name
/// minted (one per bound name + one for the exit label); the budget is left untouched (the
/// caller already charged `node_count(f.body)`).
///
/// - `f`: the callee.
/// - `args`: the call's argument `Value`s (length already matched to `f.params`).
/// - `st`: the state carrying the fresh-name counter.
/// - Return: `#(inlined_block, state_with_advanced_counter)`. Total.
fn build_inline(
  f: ir.Function,
  args: List(ir.Value),
  st: InlineState,
) -> #(ir.Expr, InlineState) {
  let param_names = list.map(f.params, fn(l) { l.name })
  let subst = list.zip(param_names, args)
  let bound = list.unique(collect_bound_names(f.body))
  let #(rename, counter1) = build_rename(bound, st.counter)
  let exit_label = "exit$inl" <> int.to_string(counter1)
  let counter2 = counter1 + 1
  let body1 = apply_rename_subst(f.body, rename, subst)
  let body2 = rewrite_returns(body1, exit_label)
  let block = ir.Block(exit_label, f.result, body2)
  #(block, InlineState(budget: st.budget, counter: counter2))
}

/// Assign each bound `name` a fresh `name$inl<n>` starting at `base`. Returns the rename map and
/// the next unused counter.
fn build_rename(
  bound: List(String),
  base: Int,
) -> #(Dict(String, String), Int) {
  let #(pairs, next) =
    list.fold(bound, #([], base), fn(acc, name) {
      let #(ps, n) = acc
      let fresh = name <> "$inl" <> int.to_string(n)
      #([#(name, fresh), ..ps], n + 1)
    })
  #(dict.from_list(pairs), next)
}

/// Rewrite every `Return(vs)` in `e` to `Break(exit_label, vs)` (the single-exit rewrite).
/// `exit_label` is fresh, so it cannot pre-exist in `e`; other transfers are untouched.
fn rewrite_returns(e: ir.Expr, exit_label: String) -> ir.Expr {
  map_expr(e, fn(node) {
    case node {
      ir.Return(vs) -> ir.Break(exit_label, vs)
      other -> other
    }
  })
}

/// Whether a `CallDirect` to `fname` is eligible to inline (heuristic gate + recursion + defined
/// guards; the budget affordability check is applied separately at the call site).
///
/// - `fname`: the callee name.
/// - `ctx`: the resolution context.
/// - Return: `True` iff `fname` is defined, non-recursive, and leaf / small / single-call-site.
///   Total.
fn eligible(fname: String, ctx: InlineCtx) -> Bool {
  case dict.get(ctx.by_name, fname) {
    Error(Nil) -> False
    Ok(f) ->
      case set.contains(ctx.recursive, fname) {
        True -> False
        False -> {
          let leaf = !has_any_call(f.body)
          let small = node_count(f.body) <= small_body_nodes
          let single = result.unwrap(dict.get(ctx.sites, fname), 0) == 1
          leaf || small || single
        }
      }
  }
}

// ─────────────────────────── rename / substitution walk ───────────────────────────

/// Apply the alpha-`rename` (bound names → fresh) and param `subst` (name → arg `Value`) to `e`
/// in one traversal. Binding positions (`Let`/`Block`/`Loop` labels + loop-param names) are
/// renamed; `Var` uses resolve param → arg first, then bound → fresh, else unchanged; module
/// globals and function names are never renamed. Capture-free because the fresh names are unique
/// in the whole caller.
fn apply_rename_subst(
  e: ir.Expr,
  rename: Dict(String, String),
  subst: List(#(String, ir.Value)),
) -> ir.Expr {
  case e {
    ir.Values(vs) -> ir.Values(rs_values(vs, rename, subst))
    ir.Num(op, args) -> ir.Num(op, rs_values(args, rename, subst))
    ir.Convert(op, arg) -> ir.Convert(op, rs_value(arg, rename, subst))
    ir.TermOp(op, args) -> ir.TermOp(op, rs_values(args, rename, subst))
    ir.MemSize -> e
    ir.MemGrow(delta) -> ir.MemGrow(rs_value(delta, rename, subst))
    ir.MemLoad(op, addr, offset, result) ->
      ir.MemLoad(op, rs_value(addr, rename, subst), offset, result)
    ir.MemStore(op, addr, value, offset) ->
      ir.MemStore(
        op,
        rs_value(addr, rename, subst),
        rs_value(value, rename, subst),
        offset,
      )
    ir.GlobalGet(_) -> e
    ir.GlobalSet(name, value) ->
      ir.GlobalSet(name, rs_value(value, rename, subst))
    ir.CallDirect(fn_name, cargs) ->
      ir.CallDirect(fn_name, rs_values(cargs, rename, subst))
    ir.CallIndirect(table, index, ty, cargs) ->
      ir.CallIndirect(
        table,
        rs_value(index, rename, subst),
        ty,
        rs_values(cargs, rename, subst),
      )
    ir.CallHost(cap, name, cargs) ->
      ir.CallHost(cap, name, rs_values(cargs, rename, subst))
    ir.Let(names, rhs, body) ->
      ir.Let(
        list.map(names, fn(n) { rename_name(n, rename) }),
        apply_rename_subst(rhs, rename, subst),
        apply_rename_subst(body, rename, subst),
      )
    ir.Block(label, result, body) ->
      ir.Block(
        rename_name(label, rename),
        result,
        apply_rename_subst(body, rename, subst),
      )
    ir.Loop(label, params, result, body) ->
      ir.Loop(
        rename_name(label, rename),
        list.map(params, fn(p) {
          ir.LoopParam(
            ..p,
            name: rename_name(p.name, rename),
            init: rs_value(p.init, rename, subst),
          )
        }),
        result,
        apply_rename_subst(body, rename, subst),
      )
    ir.If(cond, result, then_branch, else_branch) ->
      ir.If(
        rs_value(cond, rename, subst),
        result,
        apply_rename_subst(then_branch, rename, subst),
        apply_rename_subst(else_branch, rename, subst),
      )
    ir.Switch(sel, result, arms, default) ->
      ir.Switch(
        rs_value(sel, rename, subst),
        result,
        list.map(arms, fn(a) {
          ir.SwitchArm(..a, body: apply_rename_subst(a.body, rename, subst))
        }),
        apply_rename_subst(default, rename, subst),
      )
    ir.Break(label, values) ->
      ir.Break(rename_name(label, rename), rs_values(values, rename, subst))
    ir.Continue(label, values) ->
      ir.Continue(rename_name(label, rename), rs_values(values, rename, subst))
    ir.Return(values) -> ir.Return(rs_values(values, rename, subst))
    ir.Trap(_) -> e
    ir.Charge(cost, body) ->
      ir.Charge(cost, apply_rename_subst(body, rename, subst))
  }
}

/// Resolve one bound name through the alpha-`rename` map; an unmapped name is unchanged.
fn rename_name(n: String, rename: Dict(String, String)) -> String {
  case dict.get(rename, n) {
    Ok(fresh) -> fresh
    Error(Nil) -> n
  }
}

/// Resolve one `Value`: a `Var` bound as a callee param becomes its arg `Value`; a `Var` bound
/// inside the callee becomes its renamed `Var`; every other `Value` (constants, a global-free
/// unmapped `Var`) is unchanged.
fn rs_value(
  v: ir.Value,
  rename: Dict(String, String),
  subst: List(#(String, ir.Value)),
) -> ir.Value {
  case v {
    ir.Var(n) ->
      case list.key_find(subst, n) {
        Ok(arg) -> arg
        Error(Nil) ->
          case dict.get(rename, n) {
            Ok(fresh) -> ir.Var(fresh)
            Error(Nil) -> v
          }
      }
    _ -> v
  }
}

/// Map `rs_value` over a list of operands.
fn rs_values(
  vs: List(ir.Value),
  rename: Dict(String, String),
  subst: List(#(String, ir.Value)),
) -> List(ir.Value) {
  list.map(vs, fn(v) { rs_value(v, rename, subst) })
}

// ─────────────────────────── IR analyses (graph / counts / names) ───────────────────────────

/// Every name BOUND inside `e`: `Let` names, `Block`/`Loop` labels, and loop-param names. These
/// are exactly the names inlining must alpha-rename to avoid capture.
fn collect_bound_names(e: ir.Expr) -> List(String) {
  case e {
    ir.Let(names, rhs, body) ->
      list.append(
        names,
        list.append(collect_bound_names(rhs), collect_bound_names(body)),
      )
    ir.Block(label, _, body) -> [label, ..collect_bound_names(body)]
    ir.Loop(label, params, _, body) -> [
      label,
      ..list.append(
        list.map(params, fn(p) { p.name }),
        collect_bound_names(body),
      )
    ]
    ir.If(_, _, then_branch, else_branch) ->
      list.append(
        collect_bound_names(then_branch),
        collect_bound_names(else_branch),
      )
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { collect_bound_names(a.body) }),
        collect_bound_names(default),
      )
    ir.Charge(_, body) -> collect_bound_names(body)
    _ -> []
  }
}

/// The Expr-node count of `e` (each node counts 1; structured forms add their sub-nodes). The
/// callee's cost used by the budget and the small-body heuristic.
fn node_count(e: ir.Expr) -> Int {
  case e {
    ir.Let(_, rhs, body) -> 1 + node_count(rhs) + node_count(body)
    ir.Block(_, _, body) -> 1 + node_count(body)
    ir.Loop(_, _, _, body) -> 1 + node_count(body)
    ir.If(_, _, then_branch, else_branch) ->
      1 + node_count(then_branch) + node_count(else_branch)
    ir.Switch(_, _, arms, default) ->
      list.fold(arms, 1 + node_count(default), fn(acc, a) {
        acc + node_count(a.body)
      })
    ir.Charge(_, body) -> 1 + node_count(body)
    _ -> 1
  }
}

/// The total Expr-node count across every function body — the base for the size budget.
fn module_node_count(funcs: List(ir.Function)) -> Int {
  list.fold(funcs, 0, fn(acc, f) { acc + node_count(f.body) })
}

/// Does `e` contain ANY call (`CallDirect`/`CallIndirect`/`CallHost`)? A body with none is a
/// leaf callee (always inlining-eligible).
fn has_any_call(e: ir.Expr) -> Bool {
  case e {
    ir.CallDirect(_, _) | ir.CallIndirect(_, _, _, _) | ir.CallHost(_, _, _) ->
      True
    ir.Let(_, rhs, body) -> has_any_call(rhs) || has_any_call(body)
    ir.Block(_, _, body) -> has_any_call(body)
    ir.Loop(_, _, _, body) -> has_any_call(body)
    ir.If(_, _, then_branch, else_branch) ->
      has_any_call(then_branch) || has_any_call(else_branch)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) { has_any_call(a.body) }) || has_any_call(default)
    ir.Charge(_, body) -> has_any_call(body)
    _ -> False
  }
}

/// Every `CallDirect` target name in `e` (with duplicates — one per site).
fn calldirect_names(e: ir.Expr) -> List(String) {
  case e {
    ir.CallDirect(name, _) -> [name]
    ir.Let(_, rhs, body) ->
      list.append(calldirect_names(rhs), calldirect_names(body))
    ir.Block(_, _, body) -> calldirect_names(body)
    ir.Loop(_, _, _, body) -> calldirect_names(body)
    ir.If(_, _, then_branch, else_branch) ->
      list.append(calldirect_names(then_branch), calldirect_names(else_branch))
    ir.Switch(_, _, arms, default) ->
      list.append(
        list.flat_map(arms, fn(a) { calldirect_names(a.body) }),
        calldirect_names(default),
      )
    ir.Charge(_, body) -> calldirect_names(body)
    _ -> []
  }
}

/// `fn_name -> number of CallDirect sites` across every function body in `funcs`.
fn count_calls_module(funcs: List(ir.Function)) -> Dict(String, Int) {
  list.fold(funcs, dict.new(), fn(acc, f) {
    list.fold(calldirect_names(f.body), acc, fn(d, name) {
      dict.insert(d, name, result.unwrap(dict.get(d, name), 0) + 1)
    })
  })
}

/// The `CallDirect` call graph restricted to defined functions: `fn_name -> deduped list of
/// defined callees`. Imports (`CallHost`) and indirect calls are excluded — inlining only ever
/// touches same-module direct calls.
fn build_call_graph(
  funcs: List(ir.Function),
  by_name: Dict(String, ir.Function),
) -> Dict(String, List(String)) {
  list.fold(funcs, dict.new(), fn(acc, f) {
    let callees =
      calldirect_names(f.body)
      |> list.filter(fn(n) { dict.has_key(by_name, n) })
      |> list.unique
    dict.insert(acc, f.name, callees)
  })
}

/// The set of function names that are self-recursive or on a `CallDirect` cycle — i.e. every `f`
/// reachable from itself via ≥ 1 call edge. These are never inlined (the acyclic termination
/// guard).
fn recursive_names(
  funcs: List(ir.Function),
  graph: Dict(String, List(String)),
) -> Set(String) {
  let n = list.length(funcs)
  // A generous step bound (never reached in practice); `closure` also terminates naturally when
  // the visited set stops growing.
  let fuel = n * n + n + 100
  list.fold(funcs, set.new(), fn(acc, f) {
    let start = result.unwrap(dict.get(graph, f.name), [])
    let reach = closure(start, graph, set.new(), fuel)
    case set.contains(reach, f.name) {
      True -> set.insert(acc, f.name)
      False -> acc
    }
  })
}

/// Transitive closure (reachable set) over the call `graph` from a `frontier`, bounded by
/// `fuel`. Total — terminates when the frontier empties, the visited set is saturated, or the
/// fuel runs out.
fn closure(
  frontier: List(String),
  graph: Dict(String, List(String)),
  visited: Set(String),
  fuel: Int,
) -> Set(String) {
  case fuel <= 0 {
    True -> visited
    False ->
      case frontier {
        [] -> visited
        [x, ..rest] ->
          case set.contains(visited, x) {
            True -> closure(rest, graph, visited, fuel - 1)
            False -> {
              let visited2 = set.insert(visited, x)
              let succ = result.unwrap(dict.get(graph, x), [])
              closure(list.append(succ, rest), graph, visited2, fuel - 1)
            }
          }
      }
  }
}

// ─────────────────────────── orphan deletion ───────────────────────────

/// The names a function must NOT be deleted for even when orphaned: exported functions, the
/// start function, and any function named in an element segment (reachable via `CallIndirect`).
fn protected_names(module: ir.Module) -> Set(String) {
  let exported = list.map(module.exports, fn(x) { x.fn_name })
  let started = case module.start {
    option.Some(s) -> [s]
    option.None -> []
  }
  let element_refs = list.flat_map(module.elements, fn(el) { el.funcs })
  set.from_list(list.append(exported, list.append(started, element_refs)))
}

/// Keep function `name` unless it became orphaned by inlining — i.e. it WAS called in the input
/// but is no longer called in the output — and is not protected. Pre-existing dead functions
/// (never called) are left untouched.
fn keep_function(
  name: String,
  input_sites: Dict(String, Int),
  output_sites: Dict(String, Int),
  protected: Set(String),
) -> Bool {
  let was_called = result.unwrap(dict.get(input_sites, name), 0) > 0
  let still_called = result.unwrap(dict.get(output_sites, name), 0) > 0
  let became_orphan = was_called && !still_called
  !became_orphan || set.contains(protected, name)
}

// ─────────────────────────── fresh-name seeding ───────────────────────────

/// One more than the largest `$inl<n>` counter already bound anywhere in `funcs`, or `0` if
/// there are none. Seeding the fresh counter above this makes every generated name globally
/// unique across fixpoint rounds (a name dropped by a later baseline pass cannot be re-minted).
fn max_inl_counter_module(funcs: List(ir.Function)) -> Int {
  list.fold(funcs, -1, fn(acc, f) {
    list.fold(collect_bound_names(f.body), acc, fn(m, name) {
      int.max(m, inl_counter(name))
    })
  })
}

/// The `<n>` suffix of a `…$inl<n>` name, or `-1` when `name` carries no such suffix.
fn inl_counter(name: String) -> Int {
  case string.contains(name, "$inl") {
    False -> -1
    True ->
      case list.last(string.split(name, "$inl")) {
        Ok(tail) ->
          case int.parse(tail) {
            Ok(n) -> n
            Error(Nil) -> -1
          }
        Error(Nil) -> -1
      }
  }
}
