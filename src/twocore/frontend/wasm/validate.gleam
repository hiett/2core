//// Unit 10a — WASM `full` validation (the security boundary).
////
//// `validate/1` proves a decoded `wasm.Module` well-typed per the WebAssembly
//// core spec's validation rules (<https://webassembly.github.io/spec/core/valid/>)
//// using the abstract stack-typing algorithm from the appendix
//// (<https://webassembly.github.io/spec/core/appendix/algorithm.html>). It is the
//// **security boundary** (overview D4/D9): the input AST is populated from
//// UNTRUSTED bytes, so every malformation is reported as a typed `ValidateError`
//// and the validator never panics, `let assert`s, or diverges (fail-closed).
////
//// This module reads `twocore/frontend/wasm/ast` ONLY — it has **no dependency on
//// the shared IR** (so its conformance gates independently of the backend, per the
//// unit doc). The output `TypedModule` carries exactly the typing facts the lowering
//// stage (`lower.gleam`, 10b) needs so lowering never re-derives types.
////
//// Strength: **`full`** (the only Phase-1 strength — required for untrusted input;
//// `subset`/`assume_valid` are deferred and are NOT a default, D9).

import gleam/list
import gleam/result
import twocore/frontend/wasm/ast.{
  type FuncType, type Instr, type Module, type ValType,
}

// ─────────────────────────────── public types ───────────────────────────────

/// A per-function defensive cap on the number of locals (params + declared).
///
/// The spec requires the local count to fit in a `u32`, but every practical engine
/// imposes a tighter bound; this cap guards the unit-05 decoder's RLE expansion (a
/// `(count, valtype)` group with a huge count would otherwise expand to a giant
/// list). `50_000` matches common engine limits and is far above anything the
/// Phase-1 corpus needs. A function exceeding it is rejected with
/// `Error(TooManyLocals(_))`.
pub const max_locals: Int = 50_000

/// The result of validating a module: the original AST plus the typing facts that
/// lowering (10b) consumes so it never re-derives types.
///
/// - `module`: the original decoded AST, **unmutated** (10a never edits `ast.gleam`).
/// - `imported_func_count`: the funcidx offset (imports occupy `0..n-1`, defined
///   functions follow). Phase-1 has no imports (`0`), but it is kept explicit so the
///   `call`/import boundary is not baked away.
/// - `func_types`: the signature of every function indexed by **funcidx** (imports
///   then defined). Phase-1 has no imports, so this is the defined functions' types
///   in order.
/// - `func_locals`: for each **defined** function (in order), its fully-expanded
///   local types — `params ++ declared` — indexed from `0`.
pub type TypedModule {
  TypedModule(
    module: Module,
    imported_func_count: Int,
    func_types: List(FuncType),
    func_locals: List(List(ValType)),
  )
}

/// Every reason `validate` rejects a module (this stage's own error type — D4, not a
/// shared enum). Each variant captures enough context to diagnose the failure; the
/// conformance suite asserts the *variant the spec rule demands*, never message text.
///
/// - `TypeMismatch`: an operand on the abstract stack had the wrong value type for an
///   instruction (spec: the typing rule for that instruction).
/// - `Underflow`: an instruction tried to pop an operand the current block did not
///   provide (operand-stack underflow).
/// - `UnknownLocal(index)`: a `local.get/set/tee` index is out of range of the
///   function's locals.
/// - `UnknownGlobal(index)`: a `global.get/set` index is out of range (Phase-1
///   decodes no globals, so any global reference is unknown).
/// - `UnknownFunc(index)`: a `call` funcidx is out of range.
/// - `UnknownType(index)`: a `type`/blocktype `typeidx` is out of range of the
///   module's type section.
/// - `UnknownLabel(index)`: a `br`/`br_if`/`br_table` relative depth exceeds the
///   control-frame stack.
/// - `BranchArityMismatch`: a `br_table` whose targets/default do not all share the
///   same label arity (spec: all branch targets must agree).
/// - `IfElseMismatch`: an `if` with no `else` whose blocktype params differ from its
///   results (an else-less `if` is only valid when `params == results`).
/// - `UnexpectedEnd`: an `end`/`else` with no matching open control frame, or a body
///   that did not close cleanly.
/// - `TooManyLocals(count)`: the function's local count exceeds `max_locals`.
/// - `Unsupported(detail)`: a construct outside the Phase-1 validation surface (e.g.
///   `call_indirect`, which needs table types not present in the Phase-1 AST). Rejected
///   fail-closed rather than waved through.
pub type ValidateError {
  TypeMismatch
  Underflow
  UnknownLocal(index: Int)
  UnknownGlobal(index: Int)
  UnknownFunc(index: Int)
  UnknownType(index: Int)
  UnknownLabel(index: Int)
  BranchArityMismatch
  IfElseMismatch
  UnexpectedEnd
  TooManyLocals(count: Int)
  Unsupported(detail: String)
}

// ─────────────────────────────── stack-typing model ───────────────────────────────

/// A value type on the abstract operand stack: a concrete WASM `ValType` or `Unknown`
/// — the polymorphic placeholder produced after `unreachable` (the spec's "Unknown"
/// / bottom). `Unknown` unifies with any expected type.
type StackType {
  Known(ValType)
  Unknown
}

/// The opcode that opened a control frame — selects how the frame's label is typed
/// and whether an else-less `if` needs the params==results check.
type FrameKind {
  KFunc
  KBlock
  KLoop
  KIf
  KElse
}

/// One control frame (spec appendix `ctrl_frame`).
///
/// - `kind`: which structured opcode opened it.
/// - `start_types`: the frame's input types (a `loop` label targets these).
/// - `end_types`: the frame's result types (a `block`/`if` label targets these; the
///   function frame's are the function results).
/// - `height`: the operand-stack height at frame entry (its base).
/// - `unreachable`: whether the rest of the frame is stack-polymorphic (set by
///   `unreachable`/`br`/`return`/`br_table`).
type CtrlFrame {
  CtrlFrame(
    kind: FrameKind,
    start_types: List(ValType),
    end_types: List(ValType),
    height: Int,
    unreachable: Bool,
  )
}

/// The validator's threaded state: the operand-type stack (`vals`, top at head) and
/// the control-frame stack (`ctrls`, innermost at head).
type VState {
  VState(vals: List(StackType), ctrls: List(CtrlFrame))
}

// ─────────────────────────────── stack operations ───────────────────────────────

/// `True` if a stack type satisfies an expectation, honoring `Unknown` polymorphism
/// in either position (spec: `Unknown` matches any type).
fn types_match(a: StackType, b: StackType) -> Bool {
  case a, b {
    Unknown, _ -> True
    _, Unknown -> True
    Known(x), Known(y) -> x == y
  }
}

/// The innermost control frame, or `Error(UnexpectedEnd)` if there is none.
fn top_ctrl(st: VState) -> Result(CtrlFrame, ValidateError) {
  case st.ctrls {
    [f, ..] -> Ok(f)
    [] -> Error(UnexpectedEnd)
  }
}

/// Pop one operand (spec appendix `pop_val`). At the current frame's base: yields
/// `Unknown` (without popping) if the frame is polymorphic, else `Error(Underflow)`.
fn pop_val(st: VState) -> Result(#(StackType, VState), ValidateError) {
  use frame <- result.try(top_ctrl(st))
  case list.length(st.vals) == frame.height {
    True ->
      case frame.unreachable {
        True -> Ok(#(Unknown, st))
        False -> Error(Underflow)
      }
    False ->
      case st.vals {
        [t, ..rest] -> Ok(#(t, VState(..st, vals: rest)))
        [] -> Error(Underflow)
      }
  }
}

/// Pop one operand and check it matches `expect` (spec appendix `pop_val(expect)`).
fn pop_expect(st: VState, expect: ValType) -> Result(VState, ValidateError) {
  use #(t, st2) <- result.try(pop_val(st))
  case types_match(t, Known(expect)) {
    True -> Ok(st2)
    False -> Error(TypeMismatch)
  }
}

/// Push one known operand type.
fn push_val(st: VState, t: ValType) -> VState {
  VState(..st, vals: [Known(t), ..st.vals])
}

/// Push a run of operand types so the last element ends up on top (spec `push_vals`).
fn push_vals(st: VState, ts: List(ValType)) -> VState {
  list.fold(ts, st, fn(s, t) { push_val(s, t) })
}

/// Pop and check a run of operand types, last-on-top first (spec `pop_vals`).
fn pop_vals(st: VState, ts: List(ValType)) -> Result(VState, ValidateError) {
  list.try_fold(list.reverse(ts), st, fn(s, t) { pop_expect(s, t) })
}

/// Open a control frame: push it (recording the current height), then push its input
/// types (spec `push_ctrl`).
fn push_ctrl(
  st: VState,
  kind: FrameKind,
  in_types: List(ValType),
  out_types: List(ValType),
) -> VState {
  let frame =
    CtrlFrame(
      kind: kind,
      start_types: in_types,
      end_types: out_types,
      height: list.length(st.vals),
      unreachable: False,
    )
  push_vals(VState(..st, ctrls: [frame, ..st.ctrls]), in_types)
}

/// Close the innermost control frame: pop and check its result types, verify the stack
/// returned to the frame's base, then remove it (spec `pop_ctrl`). Returns the closed
/// frame. `Error(TypeMismatch)` if the height does not return to base (too many/few
/// operands left on the stack).
fn pop_ctrl(st: VState) -> Result(#(CtrlFrame, VState), ValidateError) {
  use frame <- result.try(top_ctrl(st))
  use st2 <- result.try(pop_vals(st, frame.end_types))
  case list.length(st2.vals) == frame.height {
    False -> Error(TypeMismatch)
    True ->
      case st2.ctrls {
        [_, ..rest] -> Ok(#(frame, VState(..st2, ctrls: rest)))
        [] -> Error(UnexpectedEnd)
      }
  }
}

/// The types a branch to `frame` carries: a `loop` targets its INPUT types (the head),
/// every other frame targets its result types (spec `label_types`).
fn label_types(frame: CtrlFrame) -> List(ValType) {
  case frame.kind {
    KLoop -> frame.start_types
    _ -> frame.end_types
  }
}

/// Make the rest of the innermost frame stack-polymorphic: drop operands above the
/// frame's base and mark it `unreachable` (spec `unreachable`).
fn mark_unreachable(st: VState) -> Result(VState, ValidateError) {
  use frame <- result.try(top_ctrl(st))
  let drop_n = list.length(st.vals) - frame.height
  let kept = list.drop(st.vals, drop_n)
  let frame2 = CtrlFrame(..frame, unreachable: True)
  case st.ctrls {
    [_, ..rest] -> Ok(VState(vals: kept, ctrls: [frame2, ..rest]))
    [] -> Error(UnexpectedEnd)
  }
}

// ─────────────────────────────── helpers ───────────────────────────────

/// Total list indexing: `Ok(element)` at position `i` (0-based) or `Error(Nil)`.
fn nth(xs: List(a), i: Int) -> Result(a, Nil) {
  case xs, i {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], _ ->
      case i > 0 {
        True -> nth(rest, i - 1)
        False -> Error(Nil)
      }
    [], _ -> Error(Nil)
  }
}

/// Resolve a blocktype to its `#(input_types, result_types)` (spec: a blocktype is an
/// empty type, a single valtype, or a `typeidx` giving `params -> results`).
/// `Error(UnknownType(i))` if a `typeidx` is out of range.
fn blocktype_types(
  bt: ast.BlockType,
  types: List(FuncType),
) -> Result(#(List(ValType), List(ValType)), ValidateError) {
  case bt {
    ast.BlockEmpty -> Ok(#([], []))
    ast.BlockVal(t) -> Ok(#([], [t]))
    ast.BlockTypeIdx(i) ->
      case nth(types, i) {
        Ok(ast.FuncType(params, results)) -> Ok(#(params, results))
        Error(_) -> Error(UnknownType(i))
      }
  }
}

// ─────────────────────────────── public entry point ───────────────────────────────

/// Proves `module` well-typed per WASM `full` validation and returns the typing
/// information lowering needs.
///
/// `Ok(TypedModule)` ⇒ every function body type-checks under the abstract stack
/// algorithm, every local/global/func/type/label index is in bounds, every branch
/// arity matches, and every function's local count is within `max_locals`.
/// `Error(ValidateError)` ⇒ the module is invalid; the security boundary REJECTS it
/// (fail-closed). Total over any decoded AST — never panics or diverges.
pub fn validate(module: Module) -> Result(TypedModule, ValidateError) {
  // Phase-1 funcidx space is `imports ++ defined`; imports are not decoded (0).
  let imported = module.imported_func_count
  use func_types <- result.try(resolve_func_types(module))
  use func_locals <- result.try(
    list.try_map(module.funcs, fn(f) { validate_func(f, module, func_types) }),
  )
  Ok(TypedModule(
    module: module,
    imported_func_count: imported,
    func_types: func_types,
    func_locals: func_locals,
  ))
}

/// The signature of every defined function by funcidx (Phase-1 has no imports). Each
/// function's `type_idx` must be in range, else `Error(UnknownType(_))`.
fn resolve_func_types(module: Module) -> Result(List(FuncType), ValidateError) {
  list.try_map(module.funcs, fn(f) {
    case nth(module.types, f.type_idx) {
      Ok(ft) -> Ok(ft)
      Error(_) -> Error(UnknownType(f.type_idx))
    }
  })
}

/// Validate one defined function's body and return its expanded local types
/// (`params ++ declared`). Enforces `max_locals`, sets up the function control frame
/// (whose result types are the function results — the target of `return`), runs the
/// instruction stream, and verifies the body closed cleanly (the function `end`
/// popped the frame). `Error(_)` on any typing/index violation.
fn validate_func(
  f: ast.Func,
  module: Module,
  func_types: List(FuncType),
) -> Result(List(ValType), ValidateError) {
  use sig <- result.try(case nth(module.types, f.type_idx) {
    Ok(ft) -> Ok(ft)
    Error(_) -> Error(UnknownType(f.type_idx))
  })
  let local_types = list.append(sig.params, f.locals)
  let local_count = list.length(local_types)
  case local_count > max_locals {
    True -> Error(TooManyLocals(local_count))
    False -> {
      // The implicit function frame: a `block`-like frame whose results are the
      // function's results (spec: a function body is validated as a block).
      let st0 =
        VState(vals: [], ctrls: [
          CtrlFrame(
            kind: KFunc,
            start_types: [],
            end_types: sig.results,
            height: 0,
            unreachable: False,
          ),
        ])
      use st_final <- result.try(
        list.try_fold(f.body, st0, fn(st, instr) {
          validate_instr(st, instr, module.types, func_types, local_types)
        }),
      )
      // A well-formed body's trailing `end` pops the function frame, leaving no
      // open frames. Anything else is a malformed/incomplete body.
      case st_final.ctrls {
        [] -> Ok(local_types)
        _ -> Error(UnexpectedEnd)
      }
    }
  }
}

// ─────────────────────────────── per-instruction typing ───────────────────────────────

/// Type-check one instruction against the current state, returning the advanced state
/// (spec: the typing rule for each instruction). `types` is the module's type section;
/// `func_types` the per-funcidx signatures; `locals` the current function's expanded
/// local types. Any violation is a typed `ValidateError`.
fn validate_instr(
  st: VState,
  instr: Instr,
  types: List(FuncType),
  func_types: List(FuncType),
  locals: List(ValType),
) -> Result(VState, ValidateError) {
  case instr {
    ast.Unreachable -> mark_unreachable(st)
    ast.Nop -> Ok(st)

    // structured control --------------------------------------------------------
    ast.Block(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, types))
      use st2 <- result.try(pop_vals(st, in_t))
      Ok(push_ctrl(st2, KBlock, in_t, out_t))
    }
    ast.Loop(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, types))
      use st2 <- result.try(pop_vals(st, in_t))
      Ok(push_ctrl(st2, KLoop, in_t, out_t))
    }
    ast.If(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, types))
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_vals(st2, in_t))
      Ok(push_ctrl(st3, KIf, in_t, out_t))
    }
    ast.Else -> {
      use #(frame, st2) <- result.try(pop_ctrl(st))
      case frame.kind {
        KIf ->
          // Re-open as an else frame with the same in/out so the matching `end`
          // checks the else arm against the same result types.
          Ok(push_ctrl(st2, KElse, frame.start_types, frame.end_types))
        _ -> Error(UnexpectedEnd)
      }
    }
    ast.End -> {
      use #(frame, st2) <- result.try(pop_ctrl(st))
      // An `if` frame reaching `end` directly means no `else` was present, which is
      // only valid when the params and results coincide (spec: else-less `if`).
      case frame.kind == KIf && frame.start_types != frame.end_types {
        True -> Error(IfElseMismatch)
        False -> Ok(push_vals(st2, frame.end_types))
      }
    }

    // branches ------------------------------------------------------------------
    ast.Br(l) -> {
      use frame <- result.try(label_frame(st, l))
      use st2 <- result.try(pop_vals(st, label_types(frame)))
      mark_unreachable(st2)
    }
    ast.BrIf(l) -> {
      use frame <- result.try(label_frame(st, l))
      let lt = label_types(frame)
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_vals(st2, lt))
      Ok(push_vals(st3, lt))
    }
    ast.BrTable(targets, default) -> validate_br_table(st, targets, default)
    ast.Return -> {
      // `return` targets the outermost (function) frame.
      use func_frame <- result.try(case list.last(st.ctrls) {
        Ok(fr) -> Ok(fr)
        Error(_) -> Error(UnexpectedEnd)
      })
      use st2 <- result.try(pop_vals(st, func_frame.end_types))
      mark_unreachable(st2)
    }

    // calls ---------------------------------------------------------------------
    ast.Call(f) -> {
      use sig <- result.try(case nth(func_types, f) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(UnknownFunc(f))
      })
      use st2 <- result.try(pop_vals(st, sig.params))
      Ok(push_vals(st2, sig.results))
    }
    ast.CallIndirect(..) -> Error(Unsupported("call_indirect"))

    // parametric ----------------------------------------------------------------
    ast.Drop -> {
      use #(_, st2) <- result.try(pop_val(st))
      Ok(st2)
    }
    ast.Select -> {
      use st2 <- result.try(pop_expect(st, ast.I32))
      use #(t1, st3) <- result.try(pop_val(st2))
      use #(t2, st4) <- result.try(pop_val(st3))
      case types_match(t1, t2) {
        False -> Error(TypeMismatch)
        True -> {
          // The result type is the first concrete of the two operands.
          let t = case t1 {
            Known(_) -> t1
            Unknown -> t2
          }
          Ok(VState(..st4, vals: [t, ..st4.vals]))
        }
      }
    }

    // variable access -----------------------------------------------------------
    ast.LocalGet(i) -> {
      use t <- result.try(local_type(locals, i))
      Ok(push_val(st, t))
    }
    ast.LocalSet(i) -> {
      use t <- result.try(local_type(locals, i))
      pop_expect(st, t)
    }
    ast.LocalTee(i) -> {
      use t <- result.try(local_type(locals, i))
      use st2 <- result.try(pop_expect(st, t))
      Ok(push_val(st2, t))
    }
    // Phase-1 decodes no globals, so any global index is out of bounds.
    ast.GlobalGet(i) -> Error(UnknownGlobal(i))
    ast.GlobalSet(i) -> Error(UnknownGlobal(i))

    // constants -----------------------------------------------------------------
    ast.I32Const(_) -> Ok(push_val(st, ast.I32))
    ast.I64Const(_) -> Ok(push_val(st, ast.I64))
    ast.F32Const(_) -> Ok(push_val(st, ast.F32))
    ast.F64Const(_) -> Ok(push_val(st, ast.F64))

    // numeric / comparison / conversion leaves ----------------------------------
    _ -> validate_numeric(st, instr)
  }
}

/// The control frame at relative depth `l` (0 = innermost), or `Error(UnknownLabel)`.
fn label_frame(st: VState, l: Int) -> Result(CtrlFrame, ValidateError) {
  case nth(st.ctrls, l) {
    Ok(f) -> Ok(f)
    Error(_) -> Error(UnknownLabel(l))
  }
}

/// The declared type of local `i`, or `Error(UnknownLocal(i))` if out of range.
fn local_type(locals: List(ValType), i: Int) -> Result(ValType, ValidateError) {
  case nth(locals, i) {
    Ok(t) -> Ok(t)
    Error(_) -> Error(UnknownLocal(i))
  }
}

/// Validate `br_table` (spec): pop the i32 index; every target and the default must be
/// in range and share the same label arity; each target's label types are checked
/// against the operands; finally the default's types are popped and the rest becomes
/// polymorphic. `Error(UnknownLabel)`/`Error(BranchArityMismatch)` on violations.
fn validate_br_table(
  st: VState,
  targets: List(Int),
  default: Int,
) -> Result(VState, ValidateError) {
  use st1 <- result.try(pop_expect(st, ast.I32))
  use default_frame <- result.try(label_frame(st1, default))
  let default_types = label_types(default_frame)
  let arity = list.length(default_types)
  use st2 <- result.try(
    list.try_fold(targets, st1, fn(s, n) {
      use frame <- result.try(label_frame(s, n))
      let lt = label_types(frame)
      case list.length(lt) == arity {
        False -> Error(BranchArityMismatch)
        True -> {
          // Type-check this target's operands against the stack, then restore them.
          use s2 <- result.try(pop_vals(s, lt))
          Ok(push_vals(s2, lt))
        }
      }
    }),
  )
  use st3 <- result.try(pop_vals(st2, default_types))
  mark_unreachable(st3)
}

// ─────────────────────────────── numeric typing tables ───────────────────────────────

/// Type-check a numeric / comparison / sign-extension / saturating-truncation
/// instruction by its fixed operand→result signature (spec: the numeric typing rules;
/// comparisons yield i32; `i*.eqz`/unary keep one operand).
///
/// TRANSITIONAL (unit-07 reach): the Phase-2 memory / float / conversion opcodes are
/// now DECODED (unit 07) but their typing rules belong to unit 08. They route here and
/// fall through `numeric_sig` to its sentinel `#([], [])` (no Phase-1 numeric op has an
/// empty signature). Until unit 08 types them, they are REJECTED fail-closed
/// (`Unsupported`) rather than silently accepted as no-ops — so the security boundary
/// never waves through an un-typed op. Unit 08 replaces this by adding real arms to
/// `numeric_sig` (and dedicated `validate_instr` cases for memory/global ops).
fn validate_numeric(st: VState, instr: Instr) -> Result(VState, ValidateError) {
  case numeric_sig(instr) {
    #([], []) ->
      Error(Unsupported("phase-2 op decoded but not yet typed (unit 08)"))
    #(ins, outs) -> {
      use st2 <- result.try(pop_vals(st, ins))
      Ok(push_vals(st2, outs))
    }
  }
}

/// The `#(operands, results)` signature of every Phase-1 numeric/comparison/conversion
/// leaf opcode. Binary integer ops take two same-width operands and yield one;
/// comparisons yield i32; `eqz` is unary→i32; sign-extension and saturating truncation
/// follow their spec source/target widths.
fn numeric_sig(instr: Instr) -> #(List(ValType), List(ValType)) {
  let i32 = ast.I32
  let i64 = ast.I64
  let f32 = ast.F32
  let f64 = ast.F64
  case instr {
    // i32 comparisons (yield i32)
    ast.I32Eqz -> #([i32], [i32])
    ast.I32Eq -> #([i32, i32], [i32])
    ast.I32Ne -> #([i32, i32], [i32])
    ast.I32LtS -> #([i32, i32], [i32])
    ast.I32LtU -> #([i32, i32], [i32])
    ast.I32GtS -> #([i32, i32], [i32])
    ast.I32GtU -> #([i32, i32], [i32])
    ast.I32LeS -> #([i32, i32], [i32])
    ast.I32LeU -> #([i32, i32], [i32])
    ast.I32GeS -> #([i32, i32], [i32])
    ast.I32GeU -> #([i32, i32], [i32])
    // i64 comparisons (yield i32)
    ast.I64Eqz -> #([i64], [i32])
    ast.I64Eq -> #([i64, i64], [i32])
    ast.I64Ne -> #([i64, i64], [i32])
    ast.I64LtS -> #([i64, i64], [i32])
    ast.I64LtU -> #([i64, i64], [i32])
    ast.I64GtS -> #([i64, i64], [i32])
    ast.I64GtU -> #([i64, i64], [i32])
    ast.I64LeS -> #([i64, i64], [i32])
    ast.I64LeU -> #([i64, i64], [i32])
    ast.I64GeS -> #([i64, i64], [i32])
    ast.I64GeU -> #([i64, i64], [i32])
    // i32 unary numeric
    ast.I32Clz -> #([i32], [i32])
    ast.I32Ctz -> #([i32], [i32])
    ast.I32Popcnt -> #([i32], [i32])
    // i32 binary numeric
    ast.I32Add -> #([i32, i32], [i32])
    ast.I32Sub -> #([i32, i32], [i32])
    ast.I32Mul -> #([i32, i32], [i32])
    ast.I32DivS -> #([i32, i32], [i32])
    ast.I32DivU -> #([i32, i32], [i32])
    ast.I32RemS -> #([i32, i32], [i32])
    ast.I32RemU -> #([i32, i32], [i32])
    ast.I32And -> #([i32, i32], [i32])
    ast.I32Or -> #([i32, i32], [i32])
    ast.I32Xor -> #([i32, i32], [i32])
    ast.I32Shl -> #([i32, i32], [i32])
    ast.I32ShrS -> #([i32, i32], [i32])
    ast.I32ShrU -> #([i32, i32], [i32])
    ast.I32Rotl -> #([i32, i32], [i32])
    ast.I32Rotr -> #([i32, i32], [i32])
    // i64 unary numeric
    ast.I64Clz -> #([i64], [i64])
    ast.I64Ctz -> #([i64], [i64])
    ast.I64Popcnt -> #([i64], [i64])
    // i64 binary numeric
    ast.I64Add -> #([i64, i64], [i64])
    ast.I64Sub -> #([i64, i64], [i64])
    ast.I64Mul -> #([i64, i64], [i64])
    ast.I64DivS -> #([i64, i64], [i64])
    ast.I64DivU -> #([i64, i64], [i64])
    ast.I64RemS -> #([i64, i64], [i64])
    ast.I64RemU -> #([i64, i64], [i64])
    ast.I64And -> #([i64, i64], [i64])
    ast.I64Or -> #([i64, i64], [i64])
    ast.I64Xor -> #([i64, i64], [i64])
    ast.I64Shl -> #([i64, i64], [i64])
    ast.I64ShrS -> #([i64, i64], [i64])
    ast.I64ShrU -> #([i64, i64], [i64])
    ast.I64Rotl -> #([i64, i64], [i64])
    ast.I64Rotr -> #([i64, i64], [i64])
    // sign extension (same width)
    ast.I32Extend8S -> #([i32], [i32])
    ast.I32Extend16S -> #([i32], [i32])
    ast.I64Extend8S -> #([i64], [i64])
    ast.I64Extend16S -> #([i64], [i64])
    ast.I64Extend32S -> #([i64], [i64])
    // saturating float→int truncation
    ast.I32TruncSatF32S -> #([f32], [i32])
    ast.I32TruncSatF32U -> #([f32], [i32])
    ast.I32TruncSatF64S -> #([f64], [i32])
    ast.I32TruncSatF64U -> #([f64], [i32])
    ast.I64TruncSatF32S -> #([f32], [i64])
    ast.I64TruncSatF32U -> #([f32], [i64])
    ast.I64TruncSatF64S -> #([f64], [i64])
    ast.I64TruncSatF64U -> #([f64], [i64])
    // Non-numeric instructions are handled by `validate_instr`; treat any other as
    // a no-op signature so this function stays total (unreachable in practice).
    _ -> #([], [])
  }
}
