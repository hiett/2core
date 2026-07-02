//// Unit 10b — lower a validated WASM module into the shared IR.
////
//// `lower/1` consumes a `validate.TypedModule` (10a) and produces an `ir.Module`. It
//// performs the two classic WASM-frontend jobs together (they share one SSA naming
//// context, so they live in one file):
////
//// 1. **Stack elimination / SSA.** The operand stack's shape is statically known from
////    validation, so every pushed value becomes a named binding (or an immediate
////    constant) and every pop becomes a value reference — there is **no runtime
////    stack**. Numeric ops become `ir.Num`/`ir.Convert`; consts become `ConstI32`/…
//// 2. **Structure → IR with NAMED labels (D6).** WASM branches by **numeric label
////    depth**; this stage resolves each relative depth into the IR's named-label
////    constructs at the frontend boundary — a depth NEVER reaches the IR. A `br` to a
////    `loop` becomes `Continue`, to a `block`/`if` becomes `Break`, the function frame
////    becomes `Return`.
////
//// **Mutable locals → SSA.** WASM locals are mutable; the IR is functional. A local
//// assigned anywhere inside a control construct is threaded through that construct as a
//// loop-carried `LoopParam` (for `loop`) or as an extra block/`if` result value (for
//// `block`/`if`), so the value flowing out reflects whichever path ran. Declared locals
//// are zero-initialised by an explicit `Let` at function entry (emit_core ignores
//// `ir.Function.locals`, per units 05 & 08).
////
//// Phase 2 (unit 09) extends the walk with the remaining WASM 1.0 surface: linear-memory
//// load/store (the full width matrix), `memory.size`/`memory.grow`, `global.get`/`global.set`
//// (index → a stable IR global name `g<idx>`), `call_indirect` (the single MVP table → the
//// fixed name `t0`), `select` (lowered to the existing `If`, no new IR node), and the full
//// `0xA7–0xBF` int↔float conversion block (wrap/extend/reinterpret → the existing ConvOps,
//// trapping trunc → `TruncS/U`, convert → `ConvertS/U`, demote/promote). Float binary
//// **arithmetic** (`f32/f64 add/sub/mul/div/min/max` → `FAdd..FMax`) is lowered (emit_core +
//// `rt_num` already lower these end-to-end). The 14 float unary/copysign/comparison NumOps
//// (`FAbs..FGe`) are deferred — see the NOTE in `num_op/1` (emit_core's `num_op_name` still
//// `todo`s on them, so lowering them would crash the conformance runner rather than skip).
//// It also populates the module-level IR declarations (`memory`/`globals`/`tables`/
//// `elements`/`data_segments`/`start`) from the decoded sections, lowering their
//// constant-literal init/offset expressions. The mem/global/table nodes are effects (E6):
//// stores/sets/grows are sequenced into the continuation as zero-result `Let`s and are never
//// dropped, and they never enter the Phase-1 mutable-local → `LoopParam` machinery (they
//// mutate the per-instance cell, not a WASM local).
////
//// Still out of scope (returns a typed `LowerError`, never a panic): `select_t` / reference
//// types (Phase 3), and any const-expr that is not a single `t.const`
//// (`Error(NonConstInitExpr)` — imported-global init exprs are deferred with imports).

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/validate.{type TypedModule}
import twocore/ir

// ─────────────────────────────── error type ───────────────────────────────

/// Every reason lowering fails (this stage's own type — D4). Lowering is **total**:
/// an out-of-scope construct returns `Error`, never a `panic`/`let assert`.
///
/// - `Unsupported(detail)`: a construct outside lowering scope (an imported `call`, or a
///   Phase-3 reference-type op). `detail` is a stable tag.
/// - `StackUnderflow`: the operand stack lacked an expected operand — only reachable
///   on a module that bypassed validation (fail-closed defence).
/// - `Malformed(detail)`: a structural inconsistency (e.g. an `else` with no `if`).
/// - `UnknownLocalIndex(i)`/`UnknownTypeIndex(i)`/`UnknownFuncIndex(i)`: an index out
///   of range (validation should have caught it; kept so lowering is total).
/// - `NonConstInitExpr(detail)`: a global init / element-offset / data-offset constant
///   expression that is not a single `t.const` (Phase-2 MVP accepts only constant
///   literals; `global.get` of an imported global and extended-const forms are rejected
///   here — validation already blocks them, this is fail-closed insurance). `detail` is a
///   stable tag.
pub type LowerError {
  Unsupported(detail: String)
  StackUnderflow
  Malformed(detail: String)
  UnknownLocalIndex(index: Int)
  UnknownTypeIndex(index: Int)
  UnknownFuncIndex(index: Int)
  NonConstInitExpr(detail: String)
}

// ─────────────────────────────── internal state ───────────────────────────────

/// Read-only per-module/function context threaded into the walk.
///
/// - `types`: the module's type section (for blocktype resolution).
/// - `func_types`: every function's signature indexed by funcidx.
/// - `imported`: the funcidx offset (imports occupy `0..imported-1`).
/// - `local_types`: the current function's expanded local types (`params ++ declared`),
///   as IR types, indexed from 0.
/// - `global_types`: the IR value type of each module global, indexed by globalidx
///   (mirrors `local_types`; from `TypedModule.global_types`). Drives the result type of
///   `global.get` for SSA value-type tracking and the global declarations.
type LCtx {
  LCtx(
    types: List(ast.FuncType),
    func_types: List(ast.FuncType),
    imported: Int,
    local_types: List(ir.ValType),
    global_types: List(ir.ValType),
  )
}

/// The kind of a lowering control frame — selects how a branch to it lowers and how
/// its label is typed.
type FrameKind {
  FBlock
  FLoop
  FIf
  FFunc
}

/// One lowering control frame. Unlike the validator's frame this carries the resolved
/// IR label and the SSA threading facts.
///
/// - `label`: the IR (named) label of this construct.
/// - `kind`: block / loop / if / function.
/// - `branch_arity`: stack values a `br` to this frame carries (a `loop` carries its
///   INPUT arity — the head; others carry their result arity).
/// - `out_arity`: stack values yielded on fall-through (the blocktype result arity).
/// - `result_types`: the construct's IR result types = blocktype results ++ carried
///   local types (the fall-through / exit yield).
/// - `carried`: the local indices threaded through this construct (ascending) — locals
///   assigned anywhere inside it.
type LFrame {
  LFrame(
    label: String,
    kind: FrameKind,
    branch_arity: Int,
    out_arity: Int,
    result_types: List(ir.ValType),
    carried: List(Int),
  )
}

/// The mutable-threaded lowering state.
///
/// - `stack`: the abstract operand stack of IR `Value`s (top at head) — names, never a
///   runtime stack.
/// - `locals`: each local's current SSA value (index → `Value`).
/// - `counter`: a monotonic gensym counter for fresh names/labels.
/// - `frames`: the control-frame stack, innermost (current) at head.
/// - `var_types`: every minted SSA name → its IR value type. Recorded whenever lower binds
///   a fresh name (params, declared locals, op results, loads, calls, loop params, construct
///   results). Used by `value_type` to recover a `select`'s operand type (the one result
///   type that is operand-determined, not opcode-determined). Keys are stable names that are
///   never reshuffled, so this is robust across the stack reshaping in the construct lowerers.
type LState {
  LState(
    stack: List(ir.Value),
    locals: Dict(Int, ir.Value),
    counter: Int,
    frames: List(LFrame),
    var_types: Dict(String, ir.ValType),
  )
}

/// The result of walking a straight-line instruction run within one frame: the lowered
/// expression, the instructions remaining after the frame's closing marker, and the
/// advanced gensym counter. `GEnd` closed on the frame's `end`; `GElse` closed on an
/// `else` (only inside an `if` then-branch).
type GoResult {
  GEnd(expr: ir.Expr, rest: List(ast.Instr), counter: Int)
  GElse(expr: ir.Expr, rest: List(ast.Instr), counter: Int)
}

// ─────────────────────────────── public entry point ───────────────────────────────

/// Lowers a validated module into the shared IR.
///
/// The operand stack (statically known from validation) becomes named SSA bindings and
/// structured control becomes the IR's named-label constructs (D6). Sets
/// `uses_numerics: True`. Each defined function `i` is named `"f<funcidx>"`; `ExportFunc`
/// exports become `ir.ExportFn` referencing those names. The module-level declarations are
/// populated from the decoded sections: `memory` from the single MVP memory; `globals` from
/// the global section (named `g<idx>`, with constant-literal inits); `tables` from the table
/// section (named `t<idx>`); `elements` from active element segments (each funcidx → the IR
/// name `f<funcidx>`); `data_segments` from active data segments; `start` from the start
/// section (→ `f<funcidx>`).
///
/// Returns `Ok(ir.Module)`, or `Error(LowerError)` — fail-closed, never a panic — for an
/// out-of-scope construct (`Unsupported`) or a non-constant-literal init/offset expression
/// (`NonConstInitExpr`).
pub fn lower(typed: TypedModule) -> Result(ir.Module, LowerError) {
  let module = typed.module
  use functions <- result.try(
    list.index_map(module.funcs, fn(f, i) { lower_func(f, i, typed) })
    |> result.all,
  )
  let exports =
    list.filter_map(module.exports, fn(e) {
      case e.kind {
        ast.ExportFunc -> Ok(ir.ExportFn(e.name, "f" <> int.to_string(e.index)))
        _ -> Error(Nil)
      }
    })
  use globals <- result.try(lower_globals(module))
  use elements <- result.try(lower_elements(module))
  use data_segments <- result.try(lower_data(module))
  Ok(ir.Module(
    name: "twocore@wasm@" <> module_base(module),
    uses_numerics: True,
    memories: lower_memory(module),
    globals: globals,
    imports: [],
    functions: functions,
    exports: exports,
    data_segments: data_segments,
    tables: lower_tables(module),
    elements: elements,
    start: lower_start(module),
  ))
}

/// A sanitised base for the IR module name, derived from the first function export
/// (or `"anon"`). Non-identifier characters are dropped so the emitted BEAM module
/// atom is well-formed.
fn module_base(module: ast.Module) -> String {
  case list.find(module.exports, fn(e) { e.kind == ast.ExportFunc }) {
    Ok(e) -> sanitize(e.name)
    Error(_) -> "anon"
  }
}

/// Keep only `[a-zA-Z0-9_]`; map everything else away. Falls back to `"anon"` if the
/// result is empty.
fn sanitize(name: String) -> String {
  let kept =
    name
    |> string_to_chars
    |> list.filter(is_ident_char)
    |> string_concat
  case kept {
    "" -> "anon"
    _ -> kept
  }
}

// ─────────────────────────────── per-function lowering ───────────────────────────────

/// Lower one defined function (its `defined_idx` within the code section). Names params
/// `p0..`, zero-initialises declared locals with explicit `Let`s at entry, and walks the
/// body under a function control frame whose result types are the function's results
/// (the `return` target).
fn lower_func(
  f: ast.Func,
  defined_idx: Int,
  typed: TypedModule,
) -> Result(ir.Function, LowerError) {
  let module = typed.module
  let funcidx = typed.imported_func_count + defined_idx
  use sig <- result.try(nth_err(
    module.types,
    f.type_idx,
    UnknownTypeIndex(f.type_idx),
  ))
  use local_ts_wasm <- result.try(nth_err(
    typed.func_locals,
    defined_idx,
    Malformed("missing function locals"),
  ))
  let local_types = list.map(local_ts_wasm, to_ir_vt)
  let param_count = list.length(sig.params)
  let result_types = list.map(sig.results, to_ir_vt)

  // params: named p0..p{k-1}
  let params =
    list.index_map(sig.params, fn(t, i) {
      ir.Local("p" <> int.to_string(i), to_ir_vt(t))
    })
  let param_pairs =
    list.index_map(sig.params, fn(_t, i) {
      #(i, ir.Var("p" <> int.to_string(i)))
    })

  // declared locals: fresh names, zero-initialised at entry
  let declared_types = list.drop(local_types, param_count)
  let #(decl_names, c1) = fresh_n(0, list.length(declared_types))
  let decl_pairs =
    list.index_map(decl_names, fn(name, j) { #(param_count + j, ir.Var(name)) })
  let env = dict.from_list(list.append(param_pairs, decl_pairs))
  let zero_inits = list.zip(decl_names, declared_types)

  // Seed the SSA type map with the params (`p0..`) and the zero-initialised declared
  // locals so a `select` reading a param/local recovers the right operand type.
  let param_type_pairs =
    list.index_map(sig.params, fn(t, i) {
      #("p" <> int.to_string(i), to_ir_vt(t))
    })
  let init_var_types =
    dict.from_list(list.append(
      param_type_pairs,
      list.zip(decl_names, declared_types),
    ))

  let #(flabel, c2) = fresh_label(c1)
  let func_frame =
    LFrame(
      label: flabel,
      kind: FFunc,
      branch_arity: list.length(result_types),
      out_arity: list.length(result_types),
      result_types: result_types,
      carried: [],
    )
  let ctx =
    LCtx(
      types: module.types,
      func_types: typed.func_types,
      imported: typed.imported_func_count,
      local_types: local_types,
      global_types: list.map(typed.global_types, to_ir_vt),
    )
  let st0 =
    LState(
      stack: [],
      locals: env,
      counter: c2,
      frames: [func_frame],
      var_types: init_var_types,
    )
  use body_res <- result.try(go(f.body, ctx, st0))
  use #(body_core, _rest, _c) <- result.try(expect_end(body_res))
  let body = wrap_zero_inits(zero_inits, body_core)
  Ok(ir.Function(
    name: "f" <> int.to_string(funcidx),
    params: params,
    result: result_types,
    locals: [],
    body: body,
  ))
}

/// Wrap `body` in one zero-initialising `Let` per declared local (first declared local
/// outermost). Each local is bound to its type's zero value before the body runs.
fn wrap_zero_inits(
  zero_inits: List(#(String, ir.ValType)),
  body: ir.Expr,
) -> ir.Expr {
  list.fold(list.reverse(zero_inits), body, fn(acc, pair) {
    let #(name, ty) = pair
    ir.Let([name], ir.Values([zero_value(ty)]), acc)
  })
}

// ─────────────────────────────── the instruction walk ───────────────────────────────

/// Lower a straight-line instruction run within the current frame (head of
/// `st.frames`), threading SSA state. Returns a `GoResult` once the frame's closing
/// `end`/`else` is reached. Value-producing instructions wrap a `Let` around the
/// recursively-lowered continuation; structured instructions recurse into sub-bodies;
/// control transfers resolve label depths into named-label IR and skip the dead tail.
fn go(
  instrs: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  case instrs {
    [] -> Error(Malformed("ran off end of body without a closing end"))
    [instr, ..tail] ->
      case instr {
        ast.Nop -> go(tail, ctx, st)

        // closing markers: yield the current frame's fall-through result ------------
        ast.End -> {
          use cur <- result.try(current_frame(st))
          use ft <- result.try(fallthrough(cur, st))
          Ok(GEnd(ft, tail, st.counter))
        }
        ast.Else -> {
          use cur <- result.try(current_frame(st))
          use ft <- result.try(fallthrough(cur, st))
          Ok(GElse(ft, tail, st.counter))
        }

        // constants -----------------------------------------------------------------
        ast.I32Const(v) ->
          go(tail, ctx, push(st, ir.ConstI32(unsigned_bits(v, 32))))
        ast.I64Const(v) ->
          go(tail, ctx, push(st, ir.ConstI64(unsigned_bits(v, 64))))
        ast.F32Const(bits) -> go(tail, ctx, push(st, ir.ConstF32(bits)))
        ast.F64Const(bits) -> go(tail, ctx, push(st, ir.ConstF64(bits)))

        // locals --------------------------------------------------------------------
        ast.LocalGet(i) -> {
          use v <- result.try(get_local(st, i))
          go(tail, ctx, push(st, v))
        }
        ast.LocalSet(i) -> {
          use #(v, rest_stack) <- result.try(pop1(st.stack))
          go(
            tail,
            ctx,
            LState(
              ..st,
              stack: rest_stack,
              locals: dict.insert(st.locals, i, v),
            ),
          )
        }
        ast.LocalTee(i) -> {
          use #(v, _) <- result.try(pop1(st.stack))
          go(tail, ctx, LState(..st, locals: dict.insert(st.locals, i, v)))
        }

        ast.Drop -> {
          use #(_, rest_stack) <- result.try(pop1(st.stack))
          go(tail, ctx, LState(..st, stack: rest_stack))
        }

        // calls ---------------------------------------------------------------------
        ast.Call(f) -> lower_call(f, tail, ctx, st)

        // structured control --------------------------------------------------------
        ast.Block(bt) -> lower_block(bt, tail, ctx, st)
        ast.Loop(bt) -> lower_loop(bt, tail, ctx, st)
        ast.If(bt) -> lower_if(bt, tail, ctx, st)

        // branches ------------------------------------------------------------------
        ast.Br(l) -> {
          use transfer <- result.try(build_transfer(l, st))
          use #(marker, rest) <- result.try(consume_dead(tail, 0))
          Ok(end_or_else(marker, transfer, rest, st.counter))
        }
        ast.BrIf(l) -> lower_br_if(l, tail, ctx, st)
        ast.BrTable(targets, default) ->
          lower_br_table(targets, default, tail, st)
        ast.Return -> {
          use func_frame <- result.try(case list.last(st.frames) {
            Ok(fr) -> Ok(fr)
            Error(_) -> Error(Malformed("no function frame for return"))
          })
          let vals = take_push_order(st.stack, func_frame.out_arity)
          use #(marker, rest) <- result.try(consume_dead(tail, 0))
          Ok(end_or_else(marker, ir.Return(vals), rest, st.counter))
        }
        ast.Unreachable -> {
          use #(marker, rest) <- result.try(consume_dead(tail, 0))
          Ok(end_or_else(marker, ir.Trap(ir.Unreachable), rest, st.counter))
        }

        // linear-memory loads (pop addr, push the load's result-typed value) --------
        // `MemAccess(bytes, signed)`: bytes = access width, signed = sub-word sign-extend.
        // `result` is set from the opcode suffix (it, not `MemAccess`, disambiguates e.g.
        // `i32.load8_s` from `i64.load8_s`). `m.align` is dropped (validate checked it).
        ast.I32Load(m) ->
          emit_load(ir.MemAccess(4, False), ir.TI32, m.offset, tail, ctx, st)
        ast.I64Load(m) ->
          emit_load(ir.MemAccess(8, False), ir.TI64, m.offset, tail, ctx, st)
        ast.F32Load(m) ->
          emit_load(ir.MemAccess(4, False), ir.TF32, m.offset, tail, ctx, st)
        ast.F64Load(m) ->
          emit_load(ir.MemAccess(8, False), ir.TF64, m.offset, tail, ctx, st)
        ast.I32Load8S(m) ->
          emit_load(ir.MemAccess(1, True), ir.TI32, m.offset, tail, ctx, st)
        ast.I32Load8U(m) ->
          emit_load(ir.MemAccess(1, False), ir.TI32, m.offset, tail, ctx, st)
        ast.I32Load16S(m) ->
          emit_load(ir.MemAccess(2, True), ir.TI32, m.offset, tail, ctx, st)
        ast.I32Load16U(m) ->
          emit_load(ir.MemAccess(2, False), ir.TI32, m.offset, tail, ctx, st)
        ast.I64Load8S(m) ->
          emit_load(ir.MemAccess(1, True), ir.TI64, m.offset, tail, ctx, st)
        ast.I64Load8U(m) ->
          emit_load(ir.MemAccess(1, False), ir.TI64, m.offset, tail, ctx, st)
        ast.I64Load16S(m) ->
          emit_load(ir.MemAccess(2, True), ir.TI64, m.offset, tail, ctx, st)
        ast.I64Load16U(m) ->
          emit_load(ir.MemAccess(2, False), ir.TI64, m.offset, tail, ctx, st)
        ast.I64Load32S(m) ->
          emit_load(ir.MemAccess(4, True), ir.TI64, m.offset, tail, ctx, st)
        ast.I64Load32U(m) ->
          emit_load(ir.MemAccess(4, False), ir.TI64, m.offset, tail, ctx, st)

        // linear-memory stores (pop [addr, value]; zero-result effect) ---------------
        // A store writes the low `bytes` bytes; `signed` is irrelevant → always `False`.
        ast.I32Store(m) ->
          emit_store(ir.MemAccess(4, False), m.offset, tail, ctx, st)
        ast.I64Store(m) ->
          emit_store(ir.MemAccess(8, False), m.offset, tail, ctx, st)
        ast.F32Store(m) ->
          emit_store(ir.MemAccess(4, False), m.offset, tail, ctx, st)
        ast.F64Store(m) ->
          emit_store(ir.MemAccess(8, False), m.offset, tail, ctx, st)
        ast.I32Store8(m) ->
          emit_store(ir.MemAccess(1, False), m.offset, tail, ctx, st)
        ast.I32Store16(m) ->
          emit_store(ir.MemAccess(2, False), m.offset, tail, ctx, st)
        ast.I64Store8(m) ->
          emit_store(ir.MemAccess(1, False), m.offset, tail, ctx, st)
        ast.I64Store16(m) ->
          emit_store(ir.MemAccess(2, False), m.offset, tail, ctx, st)
        ast.I64Store32(m) ->
          emit_store(ir.MemAccess(4, False), m.offset, tail, ctx, st)

        // memory size/grow ----------------------------------------------------------
        // memory index 0 (the default memory); P5-05 threads a real index for multi-memory.
        ast.MemorySize -> emit_nullary(ir.MemSize(0), ir.TI32, tail, ctx, st)
        ast.MemoryGrow ->
          emit_value_op_t(
            1,
            ir.TI32,
            fn(a) { ir.MemGrow(0, one(a)) },
            tail,
            ctx,
            st,
          )

        // globals (index → stable `g<idx>` name) ------------------------------------
        ast.GlobalGet(i) ->
          emit_nullary(ir.GlobalGet(gname(i)), global_ty(ctx, i), tail, ctx, st)
        ast.GlobalSet(i) ->
          emit_effect(
            1,
            fn(a) { ir.GlobalSet(gname(i), one(a)) },
            tail,
            ctx,
            st,
          )

        // indirect call + select ----------------------------------------------------
        ast.CallIndirect(ty, table) ->
          lower_call_indirect(ty, table, tail, ctx, st)
        ast.Select -> lower_select(tail, ctx, st)

        // numeric / comparison / conversion / float leaves --------------------------
        _ -> lower_numeric(instr, tail, ctx, st)
      }
  }
}

/// Lower a numeric/comparison instruction (→ `ir.Num`) or a conversion/sign-extension/
/// saturating-truncation (→ `ir.Convert`): pop its operands, bind a fresh name to the
/// op, push the name, and lower the continuation. Anything else is out of scope.
fn lower_numeric(
  instr: ast.Instr,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  case num_op(instr) {
    Ok(#(arity, op)) ->
      emit_value_op_t(
        arity,
        numop_result_type(op),
        fn(args) { ir.Num(op, args) },
        tail,
        ctx,
        st,
      )
    Error(_) ->
      case conv_op(instr) {
        Ok(op) ->
          emit_value_op_t(
            1,
            convop_result_type(op),
            fn(args) {
              case args {
                [a] -> ir.Convert(op, a)
                _ -> ir.Convert(op, ir.ConstI32(0))
              }
            },
            tail,
            ctx,
            st,
          )
        Error(_) -> Error(Unsupported("instruction"))
      }
  }
}

/// Pop `n` operands, bind `build(args)` (a value-producing expression) to a fresh name of
/// type `result_type`, push the name (recording its type), and lower `tail`.
/// `Error(StackUnderflow)` if fewer than `n` operands are present (only reachable on an
/// unvalidated module). The recorded `result_type` lets a later `select` recover its
/// operand type (§5 of the unit doc).
fn emit_value_op_t(
  n: Int,
  result_type: ir.ValType,
  build: fn(List(ir.Value)) -> ir.Expr,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let args = take_push_order(st.stack, n)
  case list.length(args) == n {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(st.stack, n)
      let #(name, c2) = fresh(st.counter)
      let st2 =
        record_type(
          LState(..st, stack: [ir.Var(name), ..rest_stack], counter: c2),
          name,
          result_type,
        )
      use inner <- result.try(go(tail, ctx, st2))
      Ok(wrap_let([name], build(args), inner))
    }
  }
}

/// Bind a fresh name to a nullary value-producing expression `rhs` (`MemSize` /
/// `GlobalGet`) of type `result_type`, push it (recording its type), and lower `tail`.
/// Pops nothing.
fn emit_nullary(
  rhs: ir.Expr,
  result_type: ir.ValType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let #(name, c2) = fresh(st.counter)
  let st2 =
    record_type(
      LState(..st, stack: [ir.Var(name), ..st.stack], counter: c2),
      name,
      result_type,
    )
  use inner <- result.try(go(tail, ctx, st2))
  Ok(wrap_let([name], rhs, inner))
}

/// Lower a memory load: pop the i32 address, bind `MemLoad(op, addr, offset, result)` to a
/// fresh name of type `result`, push it, and continue. `op` carries the access width/sign;
/// `result` is the opcode-determined load result type.
fn emit_load(
  op: ir.MemAccess,
  result: ir.ValType,
  offset: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  emit_value_op_t(
    1,
    result,
    fn(args) {
      case args {
        [addr] -> ir.MemLoad(0, op, addr, offset, result)
        _ -> ir.MemLoad(0, op, ir.ConstI32(0), offset, result)
      }
    },
    tail,
    ctx,
    st,
  )
}

/// Lower a memory store: pop `[addr, value]` (value is on top of the WASM stack, so it is
/// second in push order), sequence `MemStore(op, addr, value, offset)` as a zero-result
/// effect, and continue. Pushes nothing. Evaluation order is addr, then value, then the
/// store (E6) — preserved by the straight-line `Let([], …)` sequencing.
fn emit_store(
  op: ir.MemAccess,
  offset: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  emit_effect(
    2,
    fn(args) {
      case args {
        [addr, value] -> ir.MemStore(0, op, addr, value, offset)
        _ -> ir.MemStore(0, op, ir.ConstI32(0), ir.ConstI32(0), offset)
      }
    },
    tail,
    ctx,
    st,
  )
}

/// Pop `n` operands and sequence `build(args)` as a ZERO-result effect — `Let([], rhs, …)`
/// — then lower the continuation. Pushes nothing. Used by `MemStore` and `GlobalSet`, whose
/// effect must be ordered into the continuation and never dropped (E6). `Error(StackUnderflow)`
/// if fewer than `n` operands are present.
fn emit_effect(
  n: Int,
  build: fn(List(ir.Value)) -> ir.Expr,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let args = take_push_order(st.stack, n)
  case list.length(args) == n {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(st.stack, n)
      let st2 = LState(..st, stack: rest_stack)
      use inner <- result.try(go(tail, ctx, st2))
      Ok(wrap_let([], build(args), inner))
    }
  }
}

/// The single argument of a one-operand op, or a defensive `ConstI32(0)` if absent (only
/// reachable on an unvalidated module — the caller guaranteed arity 1).
fn one(args: List(ir.Value)) -> ir.Value {
  case args {
    [a] -> a
    _ -> ir.ConstI32(0)
  }
}

/// Lower `call_indirect y x`: pop the i32 table index (top of stack), then the type's
/// params (push order beneath it); bind the type's results to fresh names; push them; emit
/// `CallIndirect(table, index, ty, args)`. The `ty` is the STRUCTURAL expected type
/// `module.types[y]` (the runtime does the per-call type check, E3); the table immediate
/// `x` maps to the stable name `t<x>` (MVP reserved `0` → `"t0"`). lower carries no funcidx
/// and no `apply` — the build-controlled dispatch is the runtime's job (D3a, preserved
/// structurally). `Error(UnknownTypeIndex(y))` if `y` is out of range; `Error(StackUnderflow)`
/// if the stack lacks the index/args (both only reachable on an unvalidated module).
fn lower_call_indirect(
  type_idx: Int,
  table: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use sig <- result.try(nth_err(ctx.types, type_idx, UnknownTypeIndex(type_idx)))
  let result_ir_types = list.map(sig.results, to_ir_vt)
  let ir_ty = ir.FuncType(list.map(sig.params, to_ir_vt), result_ir_types)
  use #(index, stack1) <- result.try(pop1(st.stack))
  let pcount = list.length(sig.params)
  let args = take_push_order(stack1, pcount)
  case list.length(args) == pcount {
    False -> Error(StackUnderflow)
    True -> {
      let rest_stack = list.drop(stack1, pcount)
      let #(names, c2) = fresh_n(st.counter, list.length(sig.results))
      let result_vars = list.map(names, ir.Var)
      let st2 =
        record_types(
          LState(
            ..st,
            stack: list.append(list.reverse(result_vars), rest_stack),
            counter: c2,
          ),
          list.zip(names, result_ir_types),
        )
      use inner <- result.try(go(tail, ctx, st2))
      Ok(wrap_let(
        names,
        ir.CallIndirect(tname(table), index, ir_ty, args),
        inner,
      ))
    }
  }
}

/// Lower `select` (0x1B) to the existing `If` (no new IR node). `select` pops `cond` (top),
/// then `val2`, then `val1`; the result is `val1` iff `cond ≠ 0` (spec exec/instructions).
/// So this emits `If(cond, [t], Values([val1]), Values([val2]))` — then-arm `val1`, else-arm
/// `val2` — where `t` is the operands' shared `ValType`, recovered from `val1` via
/// `value_type`. `Error(StackUnderflow)` on an under-deep stack (unvalidated module).
fn lower_select(
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(cond, stack1) <- result.try(pop1(st.stack))
  // `val1` is deeper (pushed first), `val2` nearer the top (pushed second).
  case take_push_order(stack1, 2) {
    [val1, val2] -> {
      let t = value_type(st, val1)
      let rest_stack = list.drop(stack1, 2)
      let #(name, c2) = fresh(st.counter)
      let st2 =
        record_type(
          LState(..st, stack: [ir.Var(name), ..rest_stack], counter: c2),
          name,
          t,
        )
      use inner <- result.try(go(tail, ctx, st2))
      Ok(wrap_let(
        [name],
        ir.If(cond, [t], ir.Values([val1]), ir.Values([val2])),
        inner,
      ))
    }
    _ -> Error(StackUnderflow)
  }
}

/// Lower a direct `call f`. Pops the callee's parameters, binds its results to fresh
/// names (multi-value capable), pushes them, and continues. A funcidx below
/// `imported` (a host import) is out of Phase-1 scope.
fn lower_call(
  f: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  case f < ctx.imported {
    True -> Error(Unsupported("imported call"))
    False -> {
      use sig <- result.try(nth_err(ctx.func_types, f, UnknownFuncIndex(f)))
      let pcount = list.length(sig.params)
      let rcount = list.length(sig.results)
      let args = take_push_order(st.stack, pcount)
      case list.length(args) == pcount {
        False -> Error(StackUnderflow)
        True -> {
          let rest_stack = list.drop(st.stack, pcount)
          let #(names, c2) = fresh_n(st.counter, rcount)
          let result_vars = list.map(names, ir.Var)
          let st2 =
            record_types(
              LState(
                ..st,
                stack: list.append(list.reverse(result_vars), rest_stack),
                counter: c2,
              ),
              list.zip(names, list.map(sig.results, to_ir_vt)),
            )
          use inner <- result.try(go(tail, ctx, st2))
          Ok(wrap_let(
            names,
            ir.CallDirect("f" <> int.to_string(f), args),
            inner,
          ))
        }
      }
    }
  }
}

// ─────────────────────────────── structured-control lowering ───────────────────────────────

/// Lower a `block`. Locals assigned within it are threaded out as extra block results;
/// the body is lowered under a fresh named `Block` label whose fall-through and every
/// `Break` to it yield `[block results ++ carried locals]`.
fn lower_block(
  bt: ast.BlockType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  let carried = scan_modified(tail, 0, set.new())
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  let result_types = list.append(out_ir, carried_ts)

  let inner_stack = list.take(st.stack, in_n)
  let below = list.drop(st.stack, in_n)
  let #(label, c1) = fresh_label(st.counter)
  let frame =
    LFrame(
      label: label,
      kind: FBlock,
      branch_arity: out_n,
      out_arity: out_n,
      result_types: result_types,
      carried: carried,
    )
  let child =
    LState(
      stack: inner_stack,
      locals: st.locals,
      counter: c1,
      frames: [frame, ..st.frames],
      var_types: st.var_types,
    )
  use body_res <- result.try(go(tail, ctx, child))
  use #(body_expr, rest, c2) <- result.try(expect_end(body_res))
  finish_construct(
    ir.Block(label, result_types, body_expr),
    result_types,
    out_n,
    carried,
    below,
    rest,
    c2,
    ctx,
    st,
  )
}

/// Lower a `loop`. The blocktype params and every locally-assigned local become
/// loop-carried `LoopParam`s; the back-edge (`br` to the loop) becomes `Continue`
/// rebinding them. The constant-space tail loop is realised by emit_core.
fn lower_loop(
  bt: ast.BlockType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  let carried = scan_modified(tail, 0, set.new())
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  use carried_inits <- result.try(get_locals(st, carried))

  let in_vals = take_push_order(st.stack, in_n)
  let below = list.drop(st.stack, in_n)
  let #(lp_names, c1) = fresh_n(st.counter, in_n + list.length(carried))
  let in_names = list.take(lp_names, in_n)
  let carried_names = list.drop(lp_names, in_n)

  let in_params = zip3_loop_params(in_names, in_ir, in_vals)
  let carried_params =
    zip3_loop_params(carried_names, carried_ts, carried_inits)
  let loop_params = list.append(in_params, carried_params)
  let result_types = list.append(out_ir, carried_ts)

  let #(label, c2) = fresh_label(c1)
  let inner_stack = list.reverse(list.map(in_names, ir.Var))
  let inner_locals = update_locals(st.locals, carried, carried_names)
  // The loop-param names (the inputs on the inner stack and the carried locals) are fresh
  // SSA names: record their types so a `select` inside the loop body recovers them.
  let child_var_types =
    insert_types(
      st.var_types,
      list.append(
        list.zip(in_names, in_ir),
        list.zip(carried_names, carried_ts),
      ),
    )
  let frame =
    LFrame(
      label: label,
      kind: FLoop,
      branch_arity: in_n,
      out_arity: out_n,
      result_types: result_types,
      carried: carried,
    )
  let child =
    LState(
      stack: inner_stack,
      locals: inner_locals,
      counter: c2,
      frames: [frame, ..st.frames],
      var_types: child_var_types,
    )
  use body_res <- result.try(go(tail, ctx, child))
  use #(body_expr, rest, c3) <- result.try(expect_end(body_res))
  finish_construct(
    ir.Loop(label, loop_params, result_types, body_expr),
    result_types,
    out_n,
    carried,
    below,
    rest,
    c3,
    ctx,
    st,
  )
}

/// Lower an `if`. Pops the i32 condition; both arms start from the same operand prefix
/// and pre-`if` locals; locals assigned in either arm are threaded out as extra results.
/// A missing `else` is synthesised as an arm forwarding the params (`params == results`,
/// guaranteed by validation) and the unchanged carried locals.
fn lower_if(
  bt: ast.BlockType,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(in_ir, out_ir) <- result.try(blocktype_io(bt, ctx))
  let in_n = list.length(in_ir)
  let out_n = list.length(out_ir)
  let carried = scan_modified(tail, 0, set.new())
  use carried_ts <- result.try(carried_types(carried, ctx.local_types))
  let result_types = list.append(out_ir, carried_ts)

  use #(cond, stack1) <- result.try(pop1(st.stack))
  let inner_stack = list.take(stack1, in_n)
  let below = list.drop(stack1, in_n)
  let #(label, c1) = fresh_label(st.counter)
  let frame =
    LFrame(
      label: label,
      kind: FIf,
      branch_arity: out_n,
      out_arity: out_n,
      result_types: result_types,
      carried: carried,
    )
  let child_then =
    LState(
      stack: inner_stack,
      locals: st.locals,
      counter: c1,
      frames: [frame, ..st.frames],
      var_types: st.var_types,
    )
  use then_res <- result.try(go(tail, ctx, child_then))
  case then_res {
    GElse(then_expr, after_else, c2) -> {
      let child_else =
        LState(
          stack: inner_stack,
          locals: st.locals,
          counter: c2,
          frames: [frame, ..st.frames],
          var_types: st.var_types,
        )
      use else_res <- result.try(go(after_else, ctx, child_else))
      use #(else_expr, rest, c3) <- result.try(expect_end(else_res))
      finish_if(
        label,
        cond,
        result_types,
        then_expr,
        else_expr,
        out_n,
        carried,
        below,
        rest,
        c3,
        ctx,
        st,
      )
    }
    GEnd(then_expr, after_end, c2) -> {
      // No `else`: synthesise one forwarding the inputs (params == results) and the
      // unchanged carried locals (their pre-`if` values).
      use carried_curr <- result.try(get_locals(st, carried))
      let else_vals = list.append(list.reverse(inner_stack), carried_curr)
      let else_expr = ir.Values(else_vals)
      finish_if(
        label,
        cond,
        result_types,
        then_expr,
        else_expr,
        out_n,
        carried,
        below,
        after_end,
        c2,
        ctx,
        st,
      )
    }
  }
}

/// Bind an `if`'s results and continue lowering after it (shared by the with/without
/// `else` paths).
///
/// A WASM `if` is itself a labelled block: `br 0` (from anywhere inside, possibly nested)
/// exits the `if` forward. The IR `If` node carries **no** label, so when any branch
/// targets this `if`'s frame the lowering must give the label a home: it wraps the `If` in
/// an `ir.Block(label, result_types, If(..))` — the same `result_types`, so the wrapper is
/// arity-transparent — and the `Break(label, …)` then resolves to that block's forward
/// exit. When the `if` is *not* a branch target (the common case — `fib`/`fac`), the bare
/// `If` is emitted with no wrapper.
fn finish_if(
  label: String,
  cond: ir.Value,
  result_types: List(ir.ValType),
  then_expr: ir.Expr,
  else_expr: ir.Expr,
  out_n: Int,
  carried: List(Int),
  below: List(ir.Value),
  rest: List(ast.Instr),
  counter: Int,
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let if_expr = ir.If(cond, result_types, then_expr, else_expr)
  let construct = case
    expr_breaks_to(then_expr, label) || expr_breaks_to(else_expr, label)
  {
    True -> ir.Block(label, result_types, if_expr)
    False -> if_expr
  }
  finish_construct(
    construct,
    result_types,
    out_n,
    carried,
    below,
    rest,
    counter,
    ctx,
    st,
  )
}

/// True if `expr` contains a `Break(label, _)` — a `br` resolved to this `label`. Labels
/// are unique within a function (fresh-generated), so there is no shadowing and a plain
/// recursive scan over the structured sub-expressions is exact. Used by `finish_if` to
/// decide whether a WASM `if` needs an `ir.Block` wrapper to host its label.
fn expr_breaks_to(expr: ir.Expr, label: String) -> Bool {
  case expr {
    ir.Break(l, _) -> l == label
    ir.Let(_, rhs, body) ->
      expr_breaks_to(rhs, label) || expr_breaks_to(body, label)
    ir.If(_, _, t, e) -> expr_breaks_to(t, label) || expr_breaks_to(e, label)
    ir.Switch(_, _, arms, default) ->
      list.any(arms, fn(a) {
        let ir.SwitchArm(_, b) = a
        expr_breaks_to(b, label)
      })
      || expr_breaks_to(default, label)
    ir.Block(_, _, body) -> expr_breaks_to(body, label)
    ir.Loop(_, _, _, body) -> expr_breaks_to(body, label)
    ir.Charge(_, body) -> expr_breaks_to(body, label)
    _ -> False
  }
}

/// Bind a construct's `out_arity` stack results and its carried locals to fresh names,
/// restore the operand stack beneath it, rebind the carried locals, and lower the
/// instructions after the construct — wrapping the whole thing in a `Let`. `result_types`
/// is the construct's IR result type list (`out` types ++ carried-local types, matching
/// `res_names` 1:1); each fresh result/carried name is recorded with its type so a later
/// `select` can recover an operand's type.
fn finish_construct(
  construct: ir.Expr,
  result_types: List(ir.ValType),
  out_n: Int,
  carried: List(Int),
  below: List(ir.Value),
  rest: List(ast.Instr),
  counter: Int,
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  let #(res_names, c) = fresh_n(counter, out_n + list.length(carried))
  let res_vars = list.map(res_names, ir.Var)
  let out_vars = list.take(res_vars, out_n)
  let carried_names = list.drop(res_names, out_n)
  let new_stack = list.append(list.reverse(out_vars), below)
  let new_locals = update_locals(st.locals, carried, carried_names)
  let new_var_types =
    insert_types(st.var_types, list.zip(res_names, result_types))
  let st_parent =
    LState(
      stack: new_stack,
      locals: new_locals,
      counter: c,
      frames: st.frames,
      var_types: new_var_types,
    )
  use cont <- result.try(go(rest, ctx, st_parent))
  Ok(wrap_let(res_names, construct, cont))
}

/// Lower `br_if l`: an `If` whose then-arm is the branch transfer and whose else-arm is
/// the rest of the current body (the branch operands stay on the stack for the
/// fall-through path, per WASM semantics).
fn lower_br_if(
  l: Int,
  tail: List(ast.Instr),
  ctx: LCtx,
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(cond, stack1) <- result.try(pop1(st.stack))
  let st_nocond = LState(..st, stack: stack1)
  use transfer <- result.try(build_transfer(l, st_nocond))
  use cur <- result.try(current_frame(st))
  use inner <- result.try(go(tail, ctx, st_nocond))
  case inner {
    GEnd(e, rest, c) ->
      Ok(GEnd(ir.If(cond, cur.result_types, transfer, e), rest, c))
    GElse(e, rest, c) ->
      Ok(GElse(ir.If(cond, cur.result_types, transfer, e), rest, c))
  }
}

/// Lower `br_table`: a `Switch` on the i32 selector. Arm `i` branches to `targets[i]`,
/// the default to `default`. Each branch resolves its target frame's named label and
/// carried locals; the dead tail after the (unconditional) table is skipped.
fn lower_br_table(
  targets: List(Int),
  default: Int,
  tail: List(ast.Instr),
  st: LState,
) -> Result(GoResult, LowerError) {
  use #(sel, stack1) <- result.try(pop1(st.stack))
  let st_nosel = LState(..st, stack: stack1)
  use default_t <- result.try(build_transfer(default, st_nosel))
  use arms <- result.try(
    list.index_map(targets, fn(t, i) {
      case build_transfer(t, st_nosel) {
        Ok(tr) -> Ok(ir.SwitchArm(i, tr))
        Error(e) -> Error(e)
      }
    })
    |> result.all,
  )
  use cur <- result.try(current_frame(st))
  let switch = ir.Switch(sel, cur.result_types, arms, default_t)
  use #(marker, rest) <- result.try(consume_dead(tail, 0))
  Ok(end_or_else(marker, switch, rest, st.counter))
}

/// Build the named-label transfer for a `br` to relative depth `l`: `Continue` to a
/// `loop`, `Return` from the function frame, or `Break` to a `block`/`if`. The carried
/// values are the top `branch_arity` operands (in push order) followed by the target
/// frame's carried locals' current values.
fn build_transfer(l: Int, st: LState) -> Result(ir.Expr, LowerError) {
  use frame <- result.try(nth_err(
    st.frames,
    l,
    Malformed("branch label out of range"),
  ))
  let stack_vals = take_push_order(st.stack, frame.branch_arity)
  use carried_v <- result.try(get_locals(st, frame.carried))
  let vals = list.append(stack_vals, carried_v)
  case frame.kind {
    FLoop -> Ok(ir.Continue(frame.label, vals))
    FFunc -> Ok(ir.Return(stack_vals))
    _ -> Ok(ir.Break(frame.label, vals))
  }
}

/// The current frame's fall-through expression: forward the top `out_arity` operands
/// (push order) and the carried locals' current values as the construct's result.
fn fallthrough(cur: LFrame, st: LState) -> Result(ir.Expr, LowerError) {
  let stack_vals = take_push_order(st.stack, cur.out_arity)
  use carried_v <- result.try(get_locals(st, cur.carried))
  Ok(ir.Values(list.append(stack_vals, carried_v)))
}

// ─────────────────────────────── small helpers ───────────────────────────────

/// The current (innermost) control frame, or `Error` if the frame stack is empty.
fn current_frame(st: LState) -> Result(LFrame, LowerError) {
  case st.frames {
    [f, ..] -> Ok(f)
    [] -> Error(Malformed("no enclosing control frame"))
  }
}

/// `GEnd`/`GElse` selected by the closing marker (`end`/`else`) — used after an
/// unconditional transfer skips the dead tail.
fn end_or_else(
  marker: ast.Instr,
  expr: ir.Expr,
  rest: List(ast.Instr),
  counter: Int,
) -> GoResult {
  case marker {
    ast.Else -> GElse(expr, rest, counter)
    _ -> GEnd(expr, rest, counter)
  }
}

/// Require a `GoResult` that closed on `end` (a `block`/`loop`/function body must not be
/// closed by a stray `else`).
fn expect_end(
  gr: GoResult,
) -> Result(#(ir.Expr, List(ast.Instr), Int), LowerError) {
  case gr {
    GEnd(e, rest, c) -> Ok(#(e, rest, c))
    GElse(_, _, _) -> Error(Malformed("else without matching if"))
  }
}

/// Push a value onto the abstract operand stack.
fn push(st: LState, v: ir.Value) -> LState {
  LState(..st, stack: [v, ..st.stack])
}

/// Pop one value off the operand stack, or `Error(StackUnderflow)`.
fn pop1(
  stack: List(ir.Value),
) -> Result(#(ir.Value, List(ir.Value)), LowerError) {
  case stack {
    [v, ..rest] -> Ok(#(v, rest))
    [] -> Error(StackUnderflow)
  }
}

/// The top `n` operands in PUSH order (deepest first). Reads without modifying.
fn take_push_order(stack: List(ir.Value), n: Int) -> List(ir.Value) {
  list.reverse(list.take(stack, n))
}

/// The current SSA value of local `i`, or `Error(UnknownLocalIndex(i))`.
fn get_local(st: LState, i: Int) -> Result(ir.Value, LowerError) {
  case dict.get(st.locals, i) {
    Ok(v) -> Ok(v)
    Error(_) -> Error(UnknownLocalIndex(i))
  }
}

/// The current SSA values of `indices`, in order.
fn get_locals(
  st: LState,
  indices: List(Int),
) -> Result(List(ir.Value), LowerError) {
  list.try_map(indices, fn(i) { get_local(st, i) })
}

/// Rebind each local in `indices` to a fresh `Var(name)` (zipped pairwise).
fn update_locals(
  locals: Dict(Int, ir.Value),
  indices: List(Int),
  names: List(String),
) -> Dict(Int, ir.Value) {
  list.zip(indices, names)
  |> list.fold(locals, fn(acc, pair) {
    let #(i, name) = pair
    dict.insert(acc, i, ir.Var(name))
  })
}

/// The IR types of carried locals, or `Error(UnknownLocalIndex)` if any is out of range.
fn carried_types(
  carried: List(Int),
  local_types: List(ir.ValType),
) -> Result(List(ir.ValType), LowerError) {
  list.try_map(carried, fn(i) { nth_err(local_types, i, UnknownLocalIndex(i)) })
}

/// Build `LoopParam`s by zipping names, types, and initial values.
fn zip3_loop_params(
  names: List(String),
  types: List(ir.ValType),
  inits: List(ir.Value),
) -> List(ir.LoopParam) {
  list.zip(names, list.zip(types, inits))
  |> list.map(fn(triple) {
    let #(name, #(ty, init)) = triple
    ir.LoopParam(name, ty, init)
  })
}

/// Wrap a `Let([names], rhs, _)` around a `GoResult`'s expression (preserving its kind).
fn wrap_let(names: List(String), rhs: ir.Expr, gr: GoResult) -> GoResult {
  case gr {
    GEnd(e, rest, c) -> GEnd(ir.Let(names, rhs, e), rest, c)
    GElse(e, rest, c) -> GElse(ir.Let(names, rhs, e), rest, c)
  }
}

/// Skip the unreachable tail after an unconditional transfer until the marker that
/// closes the current frame: the `end` at depth 0, or an `else` at depth 0 (closing an
/// `if` then-branch). Nested `block`/`loop`/`if` are balanced via `depth`.
fn consume_dead(
  instrs: List(ast.Instr),
  depth: Int,
) -> Result(#(ast.Instr, List(ast.Instr)), LowerError) {
  case instrs {
    [] -> Error(Malformed("unterminated dead code"))
    [ast.Block(_), ..t] -> consume_dead(t, depth + 1)
    [ast.Loop(_), ..t] -> consume_dead(t, depth + 1)
    [ast.If(_), ..t] -> consume_dead(t, depth + 1)
    [ast.Else, ..t] ->
      case depth {
        0 -> Ok(#(ast.Else, t))
        _ -> consume_dead(t, depth)
      }
    [ast.End, ..t] ->
      case depth {
        0 -> Ok(#(ast.End, t))
        _ -> consume_dead(t, depth - 1)
      }
    [_, ..t] -> consume_dead(t, depth)
  }
}

/// The set of local indices assigned (`local.set`/`local.tee`) anywhere within the
/// current construct's body — scanned until the matching `end` (depth 0), crossing an
/// `else` for an `if`. Returned ascending (deterministic carried-local order).
fn scan_modified(
  instrs: List(ast.Instr),
  depth: Int,
  acc: set.Set(Int),
) -> List(Int) {
  case instrs {
    [] -> set_to_sorted(acc)
    [ast.Block(_), ..t] -> scan_modified(t, depth + 1, acc)
    [ast.Loop(_), ..t] -> scan_modified(t, depth + 1, acc)
    [ast.If(_), ..t] -> scan_modified(t, depth + 1, acc)
    [ast.End, ..t] ->
      case depth {
        0 -> set_to_sorted(acc)
        _ -> scan_modified(t, depth - 1, acc)
      }
    [ast.Else, ..t] -> scan_modified(t, depth, acc)
    [ast.LocalSet(i), ..t] -> scan_modified(t, depth, set.insert(acc, i))
    [ast.LocalTee(i), ..t] -> scan_modified(t, depth, set.insert(acc, i))
    [_, ..t] -> scan_modified(t, depth, acc)
  }
}

/// A set of ints as an ascending list.
fn set_to_sorted(s: set.Set(Int)) -> List(Int) {
  set.to_list(s) |> list.sort(int.compare)
}

/// Resolve a blocktype to `#(input_types, result_types)` as IR types.
fn blocktype_io(
  bt: ast.BlockType,
  ctx: LCtx,
) -> Result(#(List(ir.ValType), List(ir.ValType)), LowerError) {
  case bt {
    ast.BlockEmpty -> Ok(#([], []))
    ast.BlockVal(t) -> Ok(#([], [to_ir_vt(t)]))
    ast.BlockTypeIdx(i) ->
      case nth_err(ctx.types, i, UnknownTypeIndex(i)) {
        Ok(ast.FuncType(params, results)) ->
          Ok(#(list.map(params, to_ir_vt), list.map(results, to_ir_vt)))
        Error(e) -> Error(e)
      }
  }
}

/// Map a WASM value type to the IR value type.
fn to_ir_vt(t: ast.ValType) -> ir.ValType {
  case t {
    ast.I32 -> ir.TI32
    ast.I64 -> ir.TI64
    ast.F32 -> ir.TF32
    ast.F64 -> ir.TF64
  }
}

/// The zero value of an IR type (for declared-local initialisation). `TTerm` never
/// arises from WASM; it maps to a zero i32 defensively.
fn zero_value(t: ir.ValType) -> ir.Value {
  case t {
    ir.TI32 -> ir.ConstI32(0)
    ir.TI64 -> ir.ConstI64(0)
    ir.TF32 -> ir.ConstF32(0)
    ir.TF64 -> ir.ConstF64(0)
    ir.TTerm -> ir.ConstI32(0)
    // A reference-typed slot's zero value is the null reference (H1). Never arises from the
    // Phase-1..4 WASM surface (only numeric locals); P5-05 exercises reference locals.
    ir.TFuncRef -> ir.ConstNull(ir.FuncRef)
    ir.TExternRef -> ir.ConstNull(ir.ExternRef)
  }
}

/// Convert a possibly-negative decoded const value to its raw unsigned bit pattern in
/// `[0, 2^width)` (the IR stores integer constants as unsigned bits).
fn unsigned_bits(value: Int, width: Int) -> Int {
  case value < 0 {
    True -> value + two_pow(width)
    False -> value
  }
}

/// `2^n` for `n >= 0` (BEAM bignum). Total.
fn two_pow(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * two_pow(n - 1)
  }
}

/// Total list indexing returning `Error(err)` (the caller's chosen `LowerError`).
fn nth_err(xs: List(a), i: Int, err: LowerError) -> Result(a, LowerError) {
  case xs, i {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], _ ->
      case i > 0 {
        True -> nth_err(rest, i - 1, err)
        False -> Error(err)
      }
    [], _ -> Error(err)
  }
}

/// Generate one fresh SSA variable name and advance the counter.
fn fresh(counter: Int) -> #(String, Int) {
  #("v" <> int.to_string(counter), counter + 1)
}

/// Generate one fresh label name and advance the counter.
fn fresh_label(counter: Int) -> #(String, Int) {
  #("lbl" <> int.to_string(counter), counter + 1)
}

/// Generate `n` fresh SSA variable names and advance the counter.
fn fresh_n(counter: Int, n: Int) -> #(List(String), Int) {
  case n <= 0 {
    True -> #([], counter)
    False -> {
      let #(name, c) = fresh(counter)
      let #(rest, c2) = fresh_n(c, n - 1)
      #([name, ..rest], c2)
    }
  }
}

// ─────────────────────────────── SSA value-type tracking ───────────────────────────────

/// Record `name → ty` in the SSA type map (used to recover a `select`'s operand type).
fn record_type(st: LState, name: String, ty: ir.ValType) -> LState {
  LState(..st, var_types: dict.insert(st.var_types, name, ty))
}

/// Record many `name → ty` pairs in the SSA type map.
fn record_types(st: LState, pairs: List(#(String, ir.ValType))) -> LState {
  LState(..st, var_types: insert_types(st.var_types, pairs))
}

/// Fold a list of `#(name, type)` pairs into a `Dict(String, ValType)`.
fn insert_types(
  d: Dict(String, ir.ValType),
  pairs: List(#(String, ir.ValType)),
) -> Dict(String, ir.ValType) {
  list.fold(pairs, d, fn(acc, p) { dict.insert(acc, p.0, p.1) })
}

/// The IR value type of an operand `v`. Constants are self-describing; a `Var` looks up the
/// recorded SSA type (always present for a validated module, since every binder records its
/// type), falling back to `TI32` defensively for an unvalidated module. Used to type a
/// `select` result (§5 — every other Phase-2 result type is opcode-determined).
fn value_type(st: LState, v: ir.Value) -> ir.ValType {
  case v {
    ir.ConstI32(_) -> ir.TI32
    ir.ConstI64(_) -> ir.TI64
    ir.ConstF32(_) -> ir.TF32
    ir.ConstF64(_) -> ir.TF64
    // A null-reference literal is self-describing via its reftype tag (H1).
    ir.ConstNull(ty) -> ir.reftype_to_valtype(ty)
    ir.Var(n) -> dict.get(st.var_types, n) |> result.unwrap(ir.TI32)
  }
}

/// The stable IR global name for global index `i` (`g<idx>`). Must match emit_core /
/// instantiate (unit 10) and `GlobalDecl.name`.
fn gname(i: Int) -> String {
  "g" <> int.to_string(i)
}

/// The stable IR table name for table index `i` (`t<idx>`; MVP reserved table `0` → `"t0"`).
/// Must match `TableDecl.name`, `ElementSegment.table`, and emit_core / instantiate.
fn tname(i: Int) -> String {
  "t" <> int.to_string(i)
}

/// The declared IR value type of global `i`, for SSA type tracking of `global.get`. Falls
/// back to `TI32` for an out-of-range index (only reachable on an unvalidated module —
/// validation rejects an out-of-range global, so the lowered `GlobalGet` name is still valid).
fn global_ty(ctx: LCtx, i: Int) -> ir.ValType {
  case nth_err(ctx.global_types, i, UnknownTypeIndex(i)) {
    Ok(t) -> t
    Error(_) -> ir.TI32
  }
}

// ─────────────────────────────── module-level declarations ───────────────────────────────

/// Lower the linear memory to the IR memories vector (H3): the single MVP memory becomes a
/// one-element `[MemoryDecl(min, max, Idx32)]` (32-bit, byte-identical to Phase-4), or `[]` if
/// the module declares no memory. Multi-memory / memory64 lowering is P5-05's (the AST only
/// carries one 32-bit memory at the pin).
fn lower_memory(module: ast.Module) -> List(ir.MemoryDecl) {
  list.map(module.memories, fn(m) {
    ir.MemoryDecl(m.limits.min, m.limits.max, ir.Idx32)
  })
}

/// Lower the global section to `GlobalDecl`s in declaration (= index) order: global `i` →
/// `GlobalDecl("g<i>", type, mutable, init)` with `init` a constant-literal expression
/// (Phase-2 MVP). `Error(NonConstInitExpr(_))` if any init is not a single `t.const`.
fn lower_globals(
  module: ast.Module,
) -> Result(List(ir.GlobalDecl), LowerError) {
  list.index_map(module.globals, fn(g, i) {
    use init <- result.try(lower_const_expr(g.init))
    Ok(ir.GlobalDecl(gname(i), to_ir_vt(g.ty), g.mutable, init))
  })
  |> result.all
}

/// Lower the table section to `TableDecl`s: table `i` → `TableDecl("t<i>", min, max)`
/// (funcref implicit). MVP ⇒ at most one, named `"t0"`.
fn lower_tables(module: ast.Module) -> List(ir.TableDecl) {
  // MVP tables are funcref (byte-identical to Phase-4); `externref` tables are P5-05's.
  list.index_map(module.tables, fn(t, i) {
    ir.TableDecl(tname(i), ir.FuncRef, t.limits.min, t.limits.max)
  })
}

/// Lower active element segments: each → `ElementSegment("t<table>", offset, funcs)` where
/// `offset` is the constant-literal offset expression and each funcidx → the IR function
/// name `f<funcidx>` (the same name `lower_func` gives that funcidx, so targets resolve).
/// `Error(NonConstInitExpr(_))` on a non-constant offset.
fn lower_elements(
  module: ast.Module,
) -> Result(List(ir.ElementSegment), LowerError) {
  list.map(module.elements, fn(e) {
    use offset <- result.try(lower_const_expr(e.offset))
    // Active funcref segment (byte-identical to Phase-4): each funcidx becomes a `RefFunc`
    // init item. Passive/declarative + externref/null items are P5-05's.
    let init =
      list.map(e.funcs, fn(idx) { ir.RefFunc("f" <> int.to_string(idx)) })
    Ok(ir.ElementSegment(
      ir.ElemActive(tname(e.table), offset),
      ir.FuncRef,
      init,
    ))
  })
  |> result.all
}

/// Lower active data segments: each → `DataSegment(offset, bytes)` with `offset` the
/// constant-literal offset expression. `Error(NonConstInitExpr(_))` on a non-constant offset.
fn lower_data(module: ast.Module) -> Result(List(ir.DataSegment), LowerError) {
  list.map(module.data, fn(d) {
    use offset <- result.try(lower_const_expr(d.offset))
    // Active-at-memory-0 (byte-identical to Phase-4); passive data is P5-05's.
    Ok(ir.DataSegment(ir.DataActive(0, offset), d.bytes))
  })
  |> result.all
}

/// Lower the start section's funcidx (if present) to the IR function name `f<funcidx>`
/// (run once at instantiation). With no imports, funcidx == the start function's index.
fn lower_start(module: ast.Module) -> Option(String) {
  case module.start {
    Some(idx) -> Some("f" <> int.to_string(idx))
    None -> None
  }
}

/// Lower a constant expression (a global init / element-or-data offset) to its IR value.
/// Phase-2 MVP accepts ONLY a single `t.const` (optionally followed by a trailing `End`,
/// though decode already strips it) → `Values([the const])`. Integers are stored as their
/// raw unsigned bit pattern; floats keep their raw IEEE-754 bits (D5). Anything else
/// (notably a `global.get` imported-global form, or an extended-const chain) →
/// `Error(NonConstInitExpr(_))` — fail-closed, never a panic. (Validation already enforces
/// the const-expr rule; this is the constructive counterpart + defence.)
fn lower_const_expr(instrs: List(ast.Instr)) -> Result(ir.Expr, LowerError) {
  let stripped = case list.reverse(instrs) {
    [ast.End, ..rest] -> list.reverse(rest)
    _ -> instrs
  }
  case stripped {
    [ast.I32Const(v)] -> Ok(ir.Values([ir.ConstI32(unsigned_bits(v, 32))]))
    [ast.I64Const(v)] -> Ok(ir.Values([ir.ConstI64(unsigned_bits(v, 64))]))
    [ast.F32Const(bits)] -> Ok(ir.Values([ir.ConstF32(bits)]))
    [ast.F64Const(bits)] -> Ok(ir.Values([ir.ConstF64(bits)]))
    _ -> Error(NonConstInitExpr("non-constant init expression"))
  }
}

// ─────────────────────────────── numeric op tables ───────────────────────────────

/// Map a WASM numeric/comparison opcode to `#(operand_count, ir.NumOp)` (neutral,
/// width-tagged — D6). `Error(Nil)` for opcodes that are not `ir.Num` ops (conversions,
/// control, etc.).
fn num_op(instr: ast.Instr) -> Result(#(Int, ir.NumOp), Nil) {
  case instr {
    // i32 comparisons
    ast.I32Eqz -> Ok(#(1, ir.IEqz(ir.W32)))
    ast.I32Eq -> Ok(#(2, ir.IEq(ir.W32)))
    ast.I32Ne -> Ok(#(2, ir.INe(ir.W32)))
    ast.I32LtS -> Ok(#(2, ir.ILtS(ir.W32)))
    ast.I32LtU -> Ok(#(2, ir.ILtU(ir.W32)))
    ast.I32GtS -> Ok(#(2, ir.IGtS(ir.W32)))
    ast.I32GtU -> Ok(#(2, ir.IGtU(ir.W32)))
    ast.I32LeS -> Ok(#(2, ir.ILeS(ir.W32)))
    ast.I32LeU -> Ok(#(2, ir.ILeU(ir.W32)))
    ast.I32GeS -> Ok(#(2, ir.IGeS(ir.W32)))
    ast.I32GeU -> Ok(#(2, ir.IGeU(ir.W32)))
    // i64 comparisons
    ast.I64Eqz -> Ok(#(1, ir.IEqz(ir.W64)))
    ast.I64Eq -> Ok(#(2, ir.IEq(ir.W64)))
    ast.I64Ne -> Ok(#(2, ir.INe(ir.W64)))
    ast.I64LtS -> Ok(#(2, ir.ILtS(ir.W64)))
    ast.I64LtU -> Ok(#(2, ir.ILtU(ir.W64)))
    ast.I64GtS -> Ok(#(2, ir.IGtS(ir.W64)))
    ast.I64GtU -> Ok(#(2, ir.IGtU(ir.W64)))
    ast.I64LeS -> Ok(#(2, ir.ILeS(ir.W64)))
    ast.I64LeU -> Ok(#(2, ir.ILeU(ir.W64)))
    ast.I64GeS -> Ok(#(2, ir.IGeS(ir.W64)))
    ast.I64GeU -> Ok(#(2, ir.IGeU(ir.W64)))
    // i32 numeric
    ast.I32Clz -> Ok(#(1, ir.IClz(ir.W32)))
    ast.I32Ctz -> Ok(#(1, ir.ICtz(ir.W32)))
    ast.I32Popcnt -> Ok(#(1, ir.IPopcnt(ir.W32)))
    ast.I32Add -> Ok(#(2, ir.IAdd(ir.W32)))
    ast.I32Sub -> Ok(#(2, ir.ISub(ir.W32)))
    ast.I32Mul -> Ok(#(2, ir.IMul(ir.W32)))
    ast.I32DivS -> Ok(#(2, ir.IDivS(ir.W32)))
    ast.I32DivU -> Ok(#(2, ir.IDivU(ir.W32)))
    ast.I32RemS -> Ok(#(2, ir.IRemS(ir.W32)))
    ast.I32RemU -> Ok(#(2, ir.IRemU(ir.W32)))
    ast.I32And -> Ok(#(2, ir.IAnd(ir.W32)))
    ast.I32Or -> Ok(#(2, ir.IOr(ir.W32)))
    ast.I32Xor -> Ok(#(2, ir.IXor(ir.W32)))
    ast.I32Shl -> Ok(#(2, ir.IShl(ir.W32)))
    ast.I32ShrS -> Ok(#(2, ir.IShrS(ir.W32)))
    ast.I32ShrU -> Ok(#(2, ir.IShrU(ir.W32)))
    ast.I32Rotl -> Ok(#(2, ir.IRotl(ir.W32)))
    ast.I32Rotr -> Ok(#(2, ir.IRotr(ir.W32)))
    // i64 numeric
    ast.I64Clz -> Ok(#(1, ir.IClz(ir.W64)))
    ast.I64Ctz -> Ok(#(1, ir.ICtz(ir.W64)))
    ast.I64Popcnt -> Ok(#(1, ir.IPopcnt(ir.W64)))
    ast.I64Add -> Ok(#(2, ir.IAdd(ir.W64)))
    ast.I64Sub -> Ok(#(2, ir.ISub(ir.W64)))
    ast.I64Mul -> Ok(#(2, ir.IMul(ir.W64)))
    ast.I64DivS -> Ok(#(2, ir.IDivS(ir.W64)))
    ast.I64DivU -> Ok(#(2, ir.IDivU(ir.W64)))
    ast.I64RemS -> Ok(#(2, ir.IRemS(ir.W64)))
    ast.I64RemU -> Ok(#(2, ir.IRemU(ir.W64)))
    ast.I64And -> Ok(#(2, ir.IAnd(ir.W64)))
    ast.I64Or -> Ok(#(2, ir.IOr(ir.W64)))
    ast.I64Xor -> Ok(#(2, ir.IXor(ir.W64)))
    ast.I64Shl -> Ok(#(2, ir.IShl(ir.W64)))
    ast.I64ShrS -> Ok(#(2, ir.IShrS(ir.W64)))
    ast.I64ShrU -> Ok(#(2, ir.IShrU(ir.W64)))
    ast.I64Rotl -> Ok(#(2, ir.IRotl(ir.W64)))
    ast.I64Rotr -> Ok(#(2, ir.IRotr(ir.W64)))
    // Float binary ARITHMETIC (arity 2, → the operand's float width). These map to the
    // existing `FAdd…FMax` NumOps, which emit_core + `rt_num` already lower end-to-end
    // (Phase-1 covered them), so lowering them is complete *and* runnable.
    ast.F32Add -> Ok(#(2, ir.FAdd(ir.FW32)))
    ast.F32Sub -> Ok(#(2, ir.FSub(ir.FW32)))
    ast.F32Mul -> Ok(#(2, ir.FMul(ir.FW32)))
    ast.F32Div -> Ok(#(2, ir.FDiv(ir.FW32)))
    ast.F32Min -> Ok(#(2, ir.FMin(ir.FW32)))
    ast.F32Max -> Ok(#(2, ir.FMax(ir.FW32)))
    ast.F64Add -> Ok(#(2, ir.FAdd(ir.FW64)))
    ast.F64Sub -> Ok(#(2, ir.FSub(ir.FW64)))
    ast.F64Mul -> Ok(#(2, ir.FMul(ir.FW64)))
    ast.F64Div -> Ok(#(2, ir.FDiv(ir.FW64)))
    ast.F64Min -> Ok(#(2, ir.FMin(ir.FW64)))
    ast.F64Max -> Ok(#(2, ir.FMax(ir.FW64)))
    // Float UNARY (arity 1, → the operand's float width) and COMPARISONS (arity 2, → i32).
    // CROSS-REACH (unit 10): these were deferred only because emit_core's `num_op_name`
    // PANICKED on them; unit 10 now maps `FAbs..FGe`/`FCopysign` to the frozen `rt_num`
    // float names, so lowering them here makes the float comparison/unary modules
    // lower → emit → run end-to-end.
    ast.F32Abs -> Ok(#(1, ir.FAbs(ir.FW32)))
    ast.F32Neg -> Ok(#(1, ir.FNeg(ir.FW32)))
    ast.F32Ceil -> Ok(#(1, ir.FCeil(ir.FW32)))
    ast.F32Floor -> Ok(#(1, ir.FFloor(ir.FW32)))
    ast.F32Trunc -> Ok(#(1, ir.FTrunc(ir.FW32)))
    ast.F32Nearest -> Ok(#(1, ir.FNearest(ir.FW32)))
    ast.F32Sqrt -> Ok(#(1, ir.FSqrt(ir.FW32)))
    ast.F32Copysign -> Ok(#(2, ir.FCopysign(ir.FW32)))
    ast.F64Abs -> Ok(#(1, ir.FAbs(ir.FW64)))
    ast.F64Neg -> Ok(#(1, ir.FNeg(ir.FW64)))
    ast.F64Ceil -> Ok(#(1, ir.FCeil(ir.FW64)))
    ast.F64Floor -> Ok(#(1, ir.FFloor(ir.FW64)))
    ast.F64Trunc -> Ok(#(1, ir.FTrunc(ir.FW64)))
    ast.F64Nearest -> Ok(#(1, ir.FNearest(ir.FW64)))
    ast.F64Sqrt -> Ok(#(1, ir.FSqrt(ir.FW64)))
    ast.F64Copysign -> Ok(#(2, ir.FCopysign(ir.FW64)))
    ast.F32Eq -> Ok(#(2, ir.FEq(ir.FW32)))
    ast.F32Ne -> Ok(#(2, ir.FNe(ir.FW32)))
    ast.F32Lt -> Ok(#(2, ir.FLt(ir.FW32)))
    ast.F32Gt -> Ok(#(2, ir.FGt(ir.FW32)))
    ast.F32Le -> Ok(#(2, ir.FLe(ir.FW32)))
    ast.F32Ge -> Ok(#(2, ir.FGe(ir.FW32)))
    ast.F64Eq -> Ok(#(2, ir.FEq(ir.FW64)))
    ast.F64Ne -> Ok(#(2, ir.FNe(ir.FW64)))
    ast.F64Lt -> Ok(#(2, ir.FLt(ir.FW64)))
    ast.F64Gt -> Ok(#(2, ir.FGt(ir.FW64)))
    ast.F64Le -> Ok(#(2, ir.FLe(ir.FW64)))
    ast.F64Ge -> Ok(#(2, ir.FGe(ir.FW64)))
    _ -> Error(Nil)
  }
}

/// Map a WASM conversion opcode (sign-extension, saturating truncation, or the full
/// `0xA7–0xBF` int↔float block) to its `ir.ConvOp` (always one operand). `Error(Nil)` for
/// non-conversion opcodes.
///
/// The `0xA7–0xBF` block: `wrap`/`extend`/the 4 `reinterpret`s reuse the EXISTING ConvOps
/// (no new node); the TRAPPING `trunc_f*` map to `TruncS/U` (distinct from the saturating
/// `TruncSat*` above — lower does NOT mark them, emit_core learns which ConvOps trap);
/// `convert_i*` → `ConvertS/U`; `demote`/`promote` → `F32DemoteF64`/`F64PromoteF32`. Field
/// order is fixed by the freeze: `TruncS(from: FloatWidth, to: IntWidth)`,
/// `ConvertS(from: IntWidth, to: FloatWidth)`.
fn conv_op(instr: ast.Instr) -> Result(ir.ConvOp, Nil) {
  case instr {
    ast.I32Extend8S -> Ok(ir.I32Extend8S)
    ast.I32Extend16S -> Ok(ir.I32Extend16S)
    ast.I64Extend8S -> Ok(ir.I64Extend8S)
    ast.I64Extend16S -> Ok(ir.I64Extend16S)
    ast.I64Extend32S -> Ok(ir.I64Extend32S)
    ast.I32TruncSatF32S -> Ok(ir.TruncSatS(ir.FW32, ir.W32))
    ast.I32TruncSatF32U -> Ok(ir.TruncSatU(ir.FW32, ir.W32))
    ast.I32TruncSatF64S -> Ok(ir.TruncSatS(ir.FW64, ir.W32))
    ast.I32TruncSatF64U -> Ok(ir.TruncSatU(ir.FW64, ir.W32))
    ast.I64TruncSatF32S -> Ok(ir.TruncSatS(ir.FW32, ir.W64))
    ast.I64TruncSatF32U -> Ok(ir.TruncSatU(ir.FW32, ir.W64))
    ast.I64TruncSatF64S -> Ok(ir.TruncSatS(ir.FW64, ir.W64))
    ast.I64TruncSatF64U -> Ok(ir.TruncSatU(ir.FW64, ir.W64))
    // 0xA7–0xBF: wrap / extend / reinterpret reuse EXISTING ConvOps
    ast.I32WrapI64 -> Ok(ir.I32WrapI64)
    ast.I64ExtendI32S -> Ok(ir.I64ExtendI32S)
    ast.I64ExtendI32U -> Ok(ir.I64ExtendI32U)
    ast.I32ReinterpretF32 -> Ok(ir.ReinterpretFToI(ir.FW32))
    ast.I64ReinterpretF64 -> Ok(ir.ReinterpretFToI(ir.FW64))
    ast.F32ReinterpretI32 -> Ok(ir.ReinterpretIToF(ir.W32))
    ast.F64ReinterpretI64 -> Ok(ir.ReinterpretIToF(ir.W64))
    // 0xA8–0xB1: TRAPPING float→int truncation → TruncS/U(from, to)
    ast.I32TruncF32S -> Ok(ir.TruncS(ir.FW32, ir.W32))
    ast.I32TruncF32U -> Ok(ir.TruncU(ir.FW32, ir.W32))
    ast.I32TruncF64S -> Ok(ir.TruncS(ir.FW64, ir.W32))
    ast.I32TruncF64U -> Ok(ir.TruncU(ir.FW64, ir.W32))
    ast.I64TruncF32S -> Ok(ir.TruncS(ir.FW32, ir.W64))
    ast.I64TruncF32U -> Ok(ir.TruncU(ir.FW32, ir.W64))
    ast.I64TruncF64S -> Ok(ir.TruncS(ir.FW64, ir.W64))
    ast.I64TruncF64U -> Ok(ir.TruncU(ir.FW64, ir.W64))
    // 0xB2–0xBA: int→float conversion → ConvertS/U(from, to)
    ast.F32ConvertI32S -> Ok(ir.ConvertS(ir.W32, ir.FW32))
    ast.F32ConvertI32U -> Ok(ir.ConvertU(ir.W32, ir.FW32))
    ast.F32ConvertI64S -> Ok(ir.ConvertS(ir.W64, ir.FW32))
    ast.F32ConvertI64U -> Ok(ir.ConvertU(ir.W64, ir.FW32))
    ast.F64ConvertI32S -> Ok(ir.ConvertS(ir.W32, ir.FW64))
    ast.F64ConvertI32U -> Ok(ir.ConvertU(ir.W32, ir.FW64))
    ast.F64ConvertI64S -> Ok(ir.ConvertS(ir.W64, ir.FW64))
    ast.F64ConvertI64U -> Ok(ir.ConvertU(ir.W64, ir.FW64))
    // 0xB6 / 0xBB: float width changes
    ast.F32DemoteF64 -> Ok(ir.F32DemoteF64)
    ast.F64PromoteF32 -> Ok(ir.F64PromoteF32)
    _ -> Error(Nil)
  }
}

/// The IR result type a `NumOp` produces: integer arith/bit ops yield their width's int;
/// `Clz/Ctz/Popcnt` likewise; all comparisons (integer `IEq…`/`IEqz` and float `FEq…FGe`)
/// yield `i32`; float arith/unary (`FAdd…FCopysign`, `FAbs…FSqrt`) yield their width's float.
fn numop_result_type(op: ir.NumOp) -> ir.ValType {
  case op {
    // integer comparisons → i32
    ir.IEqz(_)
    | ir.IEq(_)
    | ir.INe(_)
    | ir.ILtS(_)
    | ir.ILtU(_)
    | ir.IGtS(_)
    | ir.IGtU(_)
    | ir.ILeS(_)
    | ir.ILeU(_)
    | ir.IGeS(_)
    | ir.IGeU(_) -> ir.TI32
    // float comparisons → i32
    ir.FEq(_) | ir.FNe(_) | ir.FLt(_) | ir.FGt(_) | ir.FLe(_) | ir.FGe(_) ->
      ir.TI32
    // integer arith / bit ops → width's int
    ir.IAdd(w)
    | ir.ISub(w)
    | ir.IMul(w)
    | ir.IDivS(w)
    | ir.IDivU(w)
    | ir.IRemS(w)
    | ir.IRemU(w)
    | ir.IAnd(w)
    | ir.IOr(w)
    | ir.IXor(w)
    | ir.IShl(w)
    | ir.IShrS(w)
    | ir.IShrU(w)
    | ir.IRotl(w)
    | ir.IRotr(w)
    | ir.IClz(w)
    | ir.ICtz(w)
    | ir.IPopcnt(w) -> int_width_ty(w)
    // float arith / unary → width's float
    ir.FAdd(w)
    | ir.FSub(w)
    | ir.FMul(w)
    | ir.FDiv(w)
    | ir.FMin(w)
    | ir.FMax(w)
    | ir.FAbs(w)
    | ir.FNeg(w)
    | ir.FCeil(w)
    | ir.FFloor(w)
    | ir.FTrunc(w)
    | ir.FNearest(w)
    | ir.FSqrt(w)
    | ir.FCopysign(w) -> float_width_ty(w)
  }
}

/// The IR result type a `ConvOp` produces (the target of the conversion). The term-boxing
/// ops never arise from WASM lowering but are mapped defensively so this stays total.
fn convop_result_type(op: ir.ConvOp) -> ir.ValType {
  case op {
    ir.I32WrapI64 -> ir.TI32
    ir.I64ExtendI32S | ir.I64ExtendI32U -> ir.TI64
    ir.I32Extend8S | ir.I32Extend16S -> ir.TI32
    ir.I64Extend8S | ir.I64Extend16S | ir.I64Extend32S -> ir.TI64
    ir.TruncSatS(_, to) | ir.TruncSatU(_, to) -> int_width_ty(to)
    ir.TruncS(_, to) | ir.TruncU(_, to) -> int_width_ty(to)
    ir.ConvertS(_, to) | ir.ConvertU(_, to) -> float_width_ty(to)
    ir.ReinterpretFToI(w) -> fwidth_to_int(w)
    ir.ReinterpretIToF(w) -> iwidth_to_float(w)
    ir.F32DemoteF64 -> ir.TF32
    ir.F64PromoteF32 -> ir.TF64
    ir.BoxInt(_) | ir.BoxFloat(_) -> ir.TTerm
    ir.UnboxInt(w) -> int_width_ty(w)
    ir.UnboxFloat(w) -> float_width_ty(w)
  }
}

/// The IR integer value type for an `IntWidth`.
fn int_width_ty(w: ir.IntWidth) -> ir.ValType {
  case w {
    ir.W32 -> ir.TI32
    ir.W64 -> ir.TI64
  }
}

/// The IR float value type for a `FloatWidth`.
fn float_width_ty(w: ir.FloatWidth) -> ir.ValType {
  case w {
    ir.FW32 -> ir.TF32
    ir.FW64 -> ir.TF64
  }
}

/// The IR integer value type matching a `FloatWidth` (a reinterpret f→i preserves bit
/// width: `FW32`→`TI32`, `FW64`→`TI64`).
fn fwidth_to_int(w: ir.FloatWidth) -> ir.ValType {
  case w {
    ir.FW32 -> ir.TI32
    ir.FW64 -> ir.TI64
  }
}

/// The IR float value type matching an `IntWidth` (a reinterpret i→f preserves bit width:
/// `W32`→`TF32`, `W64`→`TF64`).
fn iwidth_to_float(w: ir.IntWidth) -> ir.ValType {
  case w {
    ir.W32 -> ir.TF32
    ir.W64 -> ir.TF64
  }
}

// ─────────────────────────────── tiny string utilities ───────────────────────────────

/// Split a string into its character pieces (used only for export-name sanitisation).
fn string_to_chars(s: String) -> List(String) {
  string.to_graphemes(s)
}

/// Concatenate a list of strings.
fn string_concat(parts: List(String)) -> String {
  string.concat(parts)
}

/// `True` if `c` is a single `[a-zA-Z0-9_]` character.
fn is_ident_char(c: String) -> Bool {
  case c {
    "_" -> True
    _ ->
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        c,
      )
  }
}
