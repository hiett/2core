//// Unit 10a / Phase-2 unit 08 — WASM `full` validation (the security boundary).
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
//// stage (`lower.gleam`, 10b / unit 09) needs so lowering never re-derives types.
////
//// Phase 2 (unit 08) extends the Phase-1 algorithm — the polymorphic-stack /
//// label / else-less-`if` / `max_locals` machinery is kept verbatim — with typing
//// for the new ops: the load/store width matrix (+ memarg alignment), `memory.size`/
//// `memory.grow`, `global.get`/`global.set` (incl. the **mutability** check),
//// `call_indirect` (typeidx + table-presence), the float arith/unary/copysign/compare
//// ops, the full `0xA7–0xBF` int↔float conversion block, and `select`. It adds the
//// **module-level** checks (limits, ≤1 memory/table, in-range func/type/global
//// indices, the `start` signature) and **constant-expression** validation for global
//// initializers and element/data segment offsets.
////
//// Strength: **`full`** (the only Phase-1 strength — required for untrusted input;
//// `subset`/`assume_valid` are deferred and are NOT a default, D9).

import gleam/list
import gleam/option
import gleam/result
import twocore/frontend/wasm/ast.{
  type FuncType, type Instr, type Limits, type MemArg, type Module, type ValType,
}

// ─────────────────────────────── public types ───────────────────────────────

/// A per-function defensive cap on the number of locals (params + declared).
///
/// The spec requires the local count to fit in a `u32`, but every practical engine
/// imposes a tighter bound; this cap guards the unit-05 decoder's RLE expansion (a
/// `(count, valtype)` group with a huge count would otherwise expand to a giant
/// list). `50_000` matches common engine limits and is far above anything the
/// corpus needs. A function exceeding it is rejected with `Error(TooManyLocals(_))`.
pub const max_locals: Int = 50_000

/// The hard architectural cap on memory size, in 64KiB pages (`2^16`). A 32-bit
/// linear memory cannot exceed `2^16` pages = 4 GiB of address space, so a `memory`
/// whose `min`/`max` limit exceeds this is invalid (spec `valid/types`, limit
/// range `2^16` for memories).
pub const memory_page_limit: Int = 65_536

/// The hard cap on a table's size, in entries (`2^32 - 1`). The spec limit range for
/// a table is `2^32 - 1` (spec `valid/types`). Since the decoder reads `min`/`max`
/// as `u32`, this bound is only meaningful as an upper edge; the load-bearing table
/// check is `min <= max`.
pub const table_entry_limit: Int = 4_294_967_295

/// The result of validating a module: the original AST plus the typing facts that
/// lowering (10b / unit 09) consumes so it never re-derives types.
///
/// - `module`: the original decoded AST, **unmutated** (validate never edits the AST).
/// - `imported_func_count`: the funcidx offset (imports occupy `0..n-1`, defined
///   functions follow). Phase-1/2 have no imports (`0`), but it is kept explicit so
///   the `call`/import boundary is not baked away.
/// - `func_types`: the signature of every function indexed by **funcidx** (imports
///   then defined). With no imports this is the defined functions' types in order.
/// - `func_locals`: for each **defined** function (in order), its fully-expanded
///   local types — `params ++ declared` — indexed from `0`.
/// - `global_types`: the value type of each global indexed by **globalidx** (imports
///   then defined; no imports yet). This is the one typing fact lowering cannot
///   trivially re-derive from the AST and that validate must compute anyway (for the
///   `global.set` mutability check), so it is carried here. Load result types live on
///   the load opcode and `call_indirect`/`global.get` result types are recoverable
///   from `module.types`/`global_types`, so no per-instruction annotation map is needed.
pub type TypedModule {
  TypedModule(
    module: Module,
    imported_func_count: Int,
    func_types: List(FuncType),
    func_locals: List(List(ValType)),
    global_types: List(ValType),
  )
}

/// Every reason `validate` rejects a module (this stage's own error type — D4, not a
/// shared enum). Each variant captures enough context to diagnose the failure; the
/// conformance suite asserts the *variant the spec rule demands*, never message text.
///
/// - `TypeMismatch`: an operand on the abstract stack had the wrong value type for an
///   instruction, or a const-expr produced the wrong type (spec: the typing rule for
///   that instruction).
/// - `Underflow`: an instruction tried to pop an operand the current block did not
///   provide (operand-stack underflow).
/// - `UnknownLocal(index)`: a `local.get/set/tee` index is out of range of the
///   function's locals.
/// - `UnknownGlobal(index)`: a `global.get/set` index is out of range of the module's
///   globals.
/// - `UnknownFunc(index)`: a `call`/`start`/element funcidx is out of range.
/// - `UnknownType(index)`: a `type`/blocktype/`call_indirect` `typeidx` is out of
///   range of the module's type section.
/// - `UnknownLabel(index)`: a `br`/`br_if`/`br_table` relative depth exceeds the
///   control-frame stack.
/// - `UnknownMemory(index)`: a memory op (load/store/`memory.size`/`memory.grow`/an
///   active data segment) but the module declares no memory (spec: `C.mems[0]` must
///   exist).
/// - `UnknownTable(index)`: a `call_indirect`/active element segment but the module
///   declares no table (spec: `C.tables[0]` must exist).
/// - `ImmutableGlobal(index)`: a `global.set` on a `const` (immutable) global — a
///   validation error (spec `valid/instructions` `global.set` rule).
/// - `BadAlignment`: a memarg whose `2^align` exceeds the access's natural byte width
///   (spec `valid/instructions` memarg rule: `2^align <= N/8`). Routed from `align.wast`.
/// - `NonConstantExpr`: a global init / element-offset / data-offset expr uses an
///   instruction other than a single `t.const` — e.g. an extended-const `i32.add`
///   chain, or a `global.get` (valid only against an immutable imported global, none
///   of which exist in Phase 2). Spec `valid/instructions` constant expressions.
/// - `BadLimits`: a memory/table `limits` with `min > max`, or `min`/`max` exceeding
///   the type's range (`2^16` pages for a memory; `2^32 - 1` entries for a table).
///   Spec `valid/types` limits rule.
/// - `TooManyMemories`: the module declares more than one memory (MVP: at most one).
/// - `TooManyTables`: the module declares more than one table (MVP: at most one).
/// - `BadStartType`: the `start` function's type is not `[] -> []` (spec `valid/modules`
///   start rule).
/// - `BranchArityMismatch`: a `br_table` whose targets/default do not all share the
///   same label arity (spec: all branch targets must agree).
/// - `IfElseMismatch`: an `if` with no `else` whose blocktype params differ from its
///   results (an else-less `if` is only valid when `params == results`).
/// - `UnexpectedEnd`: an `end`/`else` with no matching open control frame, or a body
///   that did not close cleanly.
/// - `TooManyLocals(count)`: the function's local count exceeds `max_locals`.
/// - `Unsupported(detail)`: a construct outside the validation surface (Phase 5:
///   typed `select_t`, reference-type/bulk ops, reference-type globals/tables,
///   non-function imports, memory64, passive/expr segments). Rejected fail-closed
///   rather than waved through — P5-04 replaces these with real typing rules.
/// - `OffsetOutOfRange`: a load/store memarg static offset `>= 2^32` on a 32-bit
///   memory (spec `valid/instructions` memarg). Reachable now that decode reads the
///   offset as a `u64` (P5-03); routed from `align.wast`'s "offset out of range".
pub type ValidateError {
  TypeMismatch
  Underflow
  UnknownLocal(index: Int)
  UnknownGlobal(index: Int)
  UnknownFunc(index: Int)
  UnknownType(index: Int)
  UnknownLabel(index: Int)
  UnknownMemory(index: Int)
  UnknownTable(index: Int)
  ImmutableGlobal(index: Int)
  BadAlignment
  NonConstantExpr
  BadLimits
  TooManyMemories
  TooManyTables
  BadStartType
  BranchArityMismatch
  IfElseMismatch
  UnexpectedEnd
  TooManyLocals(count: Int)
  Unsupported(detail: String)
  OffsetOutOfRange
}

// ─────────────────────────────── validation context ───────────────────────────────

/// The module-level facts every instruction typing rule may need, threaded into
/// `validate_instr` as one record (the Phase-1 `types, func_types, locals` triple
/// generalized; the abstract-stack algorithm is otherwise untouched).
///
/// - `types`: the module's type section (resolved by blocktype/`call_indirect`).
/// - `func_types`: per-funcidx signatures (imports `++` defined; no imports yet).
/// - `globals`: `(value type, mutable?)` indexed by globalidx — drives `global.get`/
///   `global.set` typing and the mutability check.
/// - `has_memory`: whether the module declares memory 0 (a load/store/`memory.*`
///   requires it, else `UnknownMemory(0)`).
/// - `has_table`: whether the module declares table 0 (a `call_indirect`/element
///   requires it, else `UnknownTable(0)`).
/// - `locals`: the current function's expanded local types (`params ++ declared`).
type Ctx {
  Ctx(
    types: List(FuncType),
    func_types: List(FuncType),
    globals: List(#(ValType, Bool)),
    has_memory: Bool,
    has_table: Bool,
    locals: List(ValType),
  )
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
/// `Ok(TypedModule)` ⇒ every memory/table limit is in range, there is at most one
/// memory and one table, every function body type-checks under the abstract stack
/// algorithm, every local/global/func/type/label index is in bounds, every branch
/// arity matches, every function's local count is within `max_locals`, every global
/// init / element offset / data offset is a well-typed constant expression, every
/// element funcidx is in range, and any `start` function has type `[] -> []`.
/// `Error(ValidateError)` ⇒ the module is invalid; the security boundary REJECTS it
/// (fail-closed). Total over any decoded AST — never panics or diverges.
pub fn validate(module: Module) -> Result(TypedModule, ValidateError) {
  // Phase-1/2 funcidx & globalidx space is `imports ++ defined`; imports are not
  // decoded yet (count `0`), so defined index == absolute index.
  let imported = module.imported_func_count
  use func_types <- result.try(resolve_func_types(module))
  let globals = list.map(module.globals, fn(g) { #(g.ty, g.mutable) })
  let global_types = list.map(module.globals, fn(g) { g.ty })

  // Module-level structural checks (spec `valid/modules` / `valid/types`).
  use _ <- result.try(check_memories(module.memories))
  use _ <- result.try(check_tables(module.tables))

  // A module-wide context; `locals` is filled per function in `validate_func`.
  let ctx =
    Ctx(
      types: module.types,
      func_types: func_types,
      globals: globals,
      has_memory: module.memories != [],
      has_table: module.tables != [],
      locals: [],
    )

  use func_locals <- result.try(
    list.try_map(module.funcs, fn(f) { validate_func(f, module, ctx) }),
  )

  // Constant-expression validation: global inits, element & data segment offsets,
  // element funcidx range, and the `start` signature (spec `valid/modules`).
  use _ <- result.try(check_global_inits(module.globals))
  use _ <- result.try(check_elements(module, ctx))
  use _ <- result.try(check_data(module.data))
  use _ <- result.try(check_start(module, func_types))

  Ok(TypedModule(
    module: module,
    imported_func_count: imported,
    func_types: func_types,
    func_locals: func_locals,
    global_types: global_types,
  ))
}

/// The signature of every defined function by funcidx (no imports). Each function's
/// `type_idx` must be in range, else `Error(UnknownType(_))`.
fn resolve_func_types(module: Module) -> Result(List(FuncType), ValidateError) {
  list.try_map(module.funcs, fn(f) {
    case nth(module.types, f.type_idx) {
      Ok(ft) -> Ok(ft)
      Error(_) -> Error(UnknownType(f.type_idx))
    }
  })
}

/// At most one memory (MVP), whose `limits` lie within the `2^16`-page range with
/// `min <= max` (spec `valid/types`). `Error(TooManyMemories)` / `Error(BadLimits)`.
fn check_memories(mems: List(ast.MemType)) -> Result(Nil, ValidateError) {
  case mems {
    [] -> Ok(Nil)
    // A 64-bit (memory64) memory is decode/validate-only in Phase 5; its runtime is
    // deferred to Phase 6 (R12), so this Phase-2 gate rejects it fail-closed (P5-04
    // implements the real i64-address typing).
    [m] ->
      case m.idx_type {
        ast.Idx32 -> check_limits(m.limits, memory_page_limit)
        ast.Idx64 ->
          Error(Unsupported("memory64 (runtime deferred to Phase 6)"))
      }
    _ -> Error(TooManyMemories)
  }
}

/// At most one table (MVP), whose `limits` lie within the `2^32 - 1`-entry range with
/// `min <= max` (spec `valid/types`). `Error(TooManyTables)` / `Error(BadLimits)`.
fn check_tables(tabs: List(ast.TableType)) -> Result(Nil, ValidateError) {
  case tabs {
    [] -> Ok(Nil)
    // Phase-2 tables are funcref; a reference-typed (externref) table is P5-04's,
    // rejected fail-closed here.
    [t] ->
      case t.elem_type {
        ast.FuncRef -> check_limits(t.limits, table_entry_limit)
        _ -> Error(Unsupported("non-funcref table (Phase 5 surface)"))
      }
    _ -> Error(TooManyTables)
  }
}

/// A `limits` is valid within range `k` iff `min <= k`, and (when present) `max <= k`
/// and `min <= max` (spec `valid/types`: `n <= k`, `m <= k`, `n <= m`). Any violation
/// is `Error(BadLimits)`.
fn check_limits(limits: Limits, range: Int) -> Result(Nil, ValidateError) {
  case limits.min > range {
    True -> Error(BadLimits)
    False ->
      case limits.max {
        option.None -> Ok(Nil)
        option.Some(m) ->
          case m <= range && limits.min <= m {
            True -> Ok(Nil)
            False -> Error(BadLimits)
          }
      }
  }
}

/// Validate one defined function's body and return its expanded local types
/// (`params ++ declared`). Enforces `max_locals`, sets up the function control frame
/// (whose result types are the function results — the target of `return`), runs the
/// instruction stream under a per-function `Ctx`, and verifies the body closed cleanly
/// (the function `end` popped the frame). `Error(_)` on any typing/index violation.
fn validate_func(
  f: ast.Func,
  module: Module,
  ctx: Ctx,
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
      let fctx = Ctx(..ctx, locals: local_types)
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
          validate_instr(st, instr, fctx)
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
/// (spec: the typing rule for each instruction). `ctx` carries the module-level facts
/// (types, per-funcidx signatures, globals, memory/table presence) plus the current
/// function's expanded local types. Any violation is a typed `ValidateError`.
fn validate_instr(
  st: VState,
  instr: Instr,
  ctx: Ctx,
) -> Result(VState, ValidateError) {
  case instr {
    ast.Unreachable -> mark_unreachable(st)
    ast.Nop -> Ok(st)

    // structured control --------------------------------------------------------
    ast.Block(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
      use st2 <- result.try(pop_vals(st, in_t))
      Ok(push_ctrl(st2, KBlock, in_t, out_t))
    }
    ast.Loop(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
      use st2 <- result.try(pop_vals(st, in_t))
      Ok(push_ctrl(st2, KLoop, in_t, out_t))
    }
    ast.If(bt) -> {
      use #(in_t, out_t) <- result.try(blocktype_types(bt, ctx.types))
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
      use sig <- result.try(case nth(ctx.func_types, f) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(UnknownFunc(f))
      })
      use st2 <- result.try(pop_vals(st, sig.params))
      Ok(push_vals(st2, sig.results))
    }
    // `call_indirect y x`: the static `typeidx y` must be in range and a table must
    // exist (spec `valid/instructions`). Operand order: the i32 table index is on
    // top (popped first), then the type's params; the type's results are pushed. The
    // per-call structural type check is purely DYNAMIC (runtime), not validation.
    ast.CallIndirect(type_idx, _table) -> {
      use sig <- result.try(case nth(ctx.types, type_idx) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(UnknownType(type_idx))
      })
      use _ <- result.try(case ctx.has_table {
        True -> Ok(Nil)
        False -> Error(UnknownTable(0))
      })
      use st2 <- result.try(pop_expect(st, ast.I32))
      use st3 <- result.try(pop_vals(st2, sig.params))
      Ok(push_vals(st3, sig.results))
    }

    // parametric ----------------------------------------------------------------
    ast.Drop -> {
      use #(_, st2) <- result.try(pop_val(st))
      Ok(st2)
    }
    // `select` (untyped, 0x1B): `t t i32 -> t`; the two values must share a type
    // (spec). `select_t` (0x1C, typed) is deferred with reference types (Phase 3).
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
      use t <- result.try(local_type(ctx.locals, i))
      Ok(push_val(st, t))
    }
    ast.LocalSet(i) -> {
      use t <- result.try(local_type(ctx.locals, i))
      pop_expect(st, t)
    }
    ast.LocalTee(i) -> {
      use t <- result.try(local_type(ctx.locals, i))
      use st2 <- result.try(pop_expect(st, t))
      Ok(push_val(st2, t))
    }
    // `global.get i` pushes the global's type (valid on any global). `global.set i`
    // pops it, but is valid ONLY if the global is mutable (spec `valid/instructions`).
    ast.GlobalGet(i) ->
      case nth(ctx.globals, i) {
        Ok(#(ty, _)) -> Ok(push_val(st, ty))
        Error(_) -> Error(UnknownGlobal(i))
      }
    ast.GlobalSet(i) ->
      case nth(ctx.globals, i) {
        Ok(#(ty, mutable)) ->
          case mutable {
            False -> Error(ImmutableGlobal(i))
            True -> pop_expect(st, ty)
          }
        Error(_) -> Error(UnknownGlobal(i))
      }

    // constants -----------------------------------------------------------------
    ast.I32Const(_) -> Ok(push_val(st, ast.I32))
    ast.I64Const(_) -> Ok(push_val(st, ast.I64))
    ast.F32Const(_) -> Ok(push_val(st, ast.F32))
    ast.F64Const(_) -> Ok(push_val(st, ast.F64))

    // memory loads (pop i32 address, push the load's result type) ----------------
    // Each carries a memarg whose alignment must satisfy `2^align <= natural bytes`.
    ast.I32Load(m) -> check_load(st, ctx, m, ast.I32, 2)
    ast.I64Load(m) -> check_load(st, ctx, m, ast.I64, 3)
    ast.F32Load(m) -> check_load(st, ctx, m, ast.F32, 2)
    ast.F64Load(m) -> check_load(st, ctx, m, ast.F64, 3)
    ast.I32Load8S(m) -> check_load(st, ctx, m, ast.I32, 0)
    ast.I32Load8U(m) -> check_load(st, ctx, m, ast.I32, 0)
    ast.I32Load16S(m) -> check_load(st, ctx, m, ast.I32, 1)
    ast.I32Load16U(m) -> check_load(st, ctx, m, ast.I32, 1)
    ast.I64Load8S(m) -> check_load(st, ctx, m, ast.I64, 0)
    ast.I64Load8U(m) -> check_load(st, ctx, m, ast.I64, 0)
    ast.I64Load16S(m) -> check_load(st, ctx, m, ast.I64, 1)
    ast.I64Load16U(m) -> check_load(st, ctx, m, ast.I64, 1)
    ast.I64Load32S(m) -> check_load(st, ctx, m, ast.I64, 2)
    ast.I64Load32U(m) -> check_load(st, ctx, m, ast.I64, 2)

    // memory stores (pop value then i32 address; push nothing) -------------------
    // The `signed` distinction is irrelevant for stores (a store writes the low N
    // bits), so it is not part of the value type. Alignment is checked as for loads.
    ast.I32Store(m) -> check_store(st, ctx, m, ast.I32, 2)
    ast.I64Store(m) -> check_store(st, ctx, m, ast.I64, 3)
    ast.F32Store(m) -> check_store(st, ctx, m, ast.F32, 2)
    ast.F64Store(m) -> check_store(st, ctx, m, ast.F64, 3)
    ast.I32Store8(m) -> check_store(st, ctx, m, ast.I32, 0)
    ast.I32Store16(m) -> check_store(st, ctx, m, ast.I32, 1)
    ast.I64Store8(m) -> check_store(st, ctx, m, ast.I64, 0)
    ast.I64Store16(m) -> check_store(st, ctx, m, ast.I64, 1)
    ast.I64Store32(m) -> check_store(st, ctx, m, ast.I64, 2)

    // memory size/grow (require a memory) ---------------------------------------
    // The memidx is threaded by P5-05; Phase-2 validation only requires memory 0.
    ast.MemorySize(_) ->
      case require_memory(ctx) {
        Ok(_) -> Ok(push_val(st, ast.I32))
        Error(e) -> Error(e)
      }
    ast.MemoryGrow(_) -> {
      use _ <- result.try(require_memory(ctx))
      use st2 <- result.try(pop_expect(st, ast.I32))
      Ok(push_val(st2, ast.I32))
    }

    // numeric / comparison / conversion / float leaves --------------------------
    _ -> validate_numeric(st, instr)
  }
}

/// Type a memory load: require a memory, check the memarg alignment, pop the `i32`
/// address, push the load's `result` type. `max_align` is the log2 of the natural
/// access byte-width (e.g. `2` for a 4-byte access).
fn check_load(
  st: VState,
  ctx: Ctx,
  memarg: MemArg,
  result: ValType,
  max_align: Int,
) -> Result(VState, ValidateError) {
  use _ <- result.try(require_memory(ctx))
  use _ <- result.try(check_align(memarg, max_align))
  use _ <- result.try(check_offset(memarg))
  use st2 <- result.try(pop_expect(st, ast.I32))
  Ok(push_val(st2, result))
}

/// Type a memory store: require a memory, check the memarg alignment, pop the `value`
/// (top of stack) then the `i32` address, push nothing. `max_align` is as `check_load`.
fn check_store(
  st: VState,
  ctx: Ctx,
  memarg: MemArg,
  value: ValType,
  max_align: Int,
) -> Result(VState, ValidateError) {
  use _ <- result.try(require_memory(ctx))
  use _ <- result.try(check_align(memarg, max_align))
  use _ <- result.try(check_offset(memarg))
  use st2 <- result.try(pop_expect(st, value))
  pop_expect(st2, ast.I32)
}

/// The module must declare memory 0 for any memory op (load/store/`memory.*`/active
/// data segment). `Error(UnknownMemory(0))` otherwise (spec: `C.mems[0]` must exist).
fn require_memory(ctx: Ctx) -> Result(Nil, ValidateError) {
  case ctx.has_memory {
    True -> Ok(Nil)
    False -> Error(UnknownMemory(0))
  }
}

/// Validate a memarg's alignment (spec `valid/instructions` memarg rule): "the
/// alignment `2^align` must not be larger than `N/8`". Since `N/8 = 2^max_align`,
/// this is exactly `align <= max_align`; a larger `align` is `Error(BadAlignment)`.
/// Alignment is a non-semantic hint — under-alignment is always legal and never
/// rejected; the value is discarded after this check.
fn check_align(memarg: MemArg, max_align: Int) -> Result(Nil, ValidateError) {
  case memarg.align > max_align {
    True -> Error(BadAlignment)
    False -> Ok(Nil)
  }
}

/// The static memarg offset must fit the memory's address range (spec
/// `valid/instructions` memarg rule). Decode reads the offset as a `u64` (the
/// memory64 width, P5-03), and Phase-5 validate only accepts 32-bit (`Idx32`)
/// memories (memory64's runtime is deferred — R12), so a valid offset is `< 2^32`.
/// A larger offset (e.g. `align.wast`'s "offset out of range" case) is
/// `Error(OffsetOutOfRange)`. P5-04 generalizes this to the memory's real idx_type.
fn check_offset(memarg: MemArg) -> Result(Nil, ValidateError) {
  case memarg.offset >= 4_294_967_296 {
    True -> Error(OffsetOutOfRange)
    False -> Ok(Nil)
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

// ─────────────────────────────── constant expressions & module items ───────────────────────────────

/// A constant expression (global init / element offset / data offset) is valid iff it
/// reduces to a single `t.const` of `expected` (spec `valid/instructions`, constant
/// expressions). `global.get x` is valid only against an immutable IMPORTED global —
/// none exist in Phase 2, so it is rejected; extended-const forms (`i32.add`, …) and
/// any other instruction are also rejected (`NonConstantExpr`). A const of the wrong
/// type is `TypeMismatch`. (When imports land in Phase 3, the deferred `global.get`
/// case will consult the imported-global table here.)
fn validate_const_expr(
  init: List(Instr),
  expected: ValType,
) -> Result(Nil, ValidateError) {
  case init {
    [ast.I32Const(_)] -> expect_const_type(ast.I32, expected)
    [ast.I64Const(_)] -> expect_const_type(ast.I64, expected)
    [ast.F32Const(_)] -> expect_const_type(ast.F32, expected)
    [ast.F64Const(_)] -> expect_const_type(ast.F64, expected)
    _ -> Error(NonConstantExpr)
  }
}

/// `Ok(Nil)` if a const-expr's produced type matches `expected`, else `TypeMismatch`.
fn expect_const_type(
  actual: ValType,
  expected: ValType,
) -> Result(Nil, ValidateError) {
  case actual == expected {
    True -> Ok(Nil)
    False -> Error(TypeMismatch)
  }
}

/// Every global's init expr is a constant expression of the global's declared type
/// (spec `valid/modules` globals). `Error(NonConstantExpr)`/`Error(TypeMismatch)`.
fn check_global_inits(globals: List(ast.Global)) -> Result(Nil, ValidateError) {
  list.try_each(globals, fn(g) { validate_const_expr(g.init, g.ty) })
}

/// Every active element segment: a table must exist, its offset is an `i32` constant
/// expression, and every funcidx it writes is in the function index space (spec
/// `valid/modules` elements). `Error(UnknownTable(0))`/`NonConstantExpr`/`TypeMismatch`/
/// `UnknownFunc(_)`.
fn check_elements(module: Module, ctx: Ctx) -> Result(Nil, ValidateError) {
  let func_count = module.imported_func_count + list.length(module.funcs)
  list.try_each(module.elements, fn(e) {
    // Phase-2 case: an active funcref segment into table 0 with a funcidx list.
    // Passive/declarative modes, expr-init, explicit tableidx, and externref
    // segments are P5-04's — rejected fail-closed here.
    case e.mode, e.init, e.ref_ty {
      ast.ElemActive(0, offset), ast.ElemFuncs(funcs), ast.FuncRef -> {
        use _ <- result.try(case ctx.has_table {
          True -> Ok(Nil)
          False -> Error(UnknownTable(0))
        })
        use _ <- result.try(validate_const_expr(offset, ast.I32))
        list.try_each(funcs, fn(idx) {
          case idx >= 0 && idx < func_count {
            True -> Ok(Nil)
            False -> Error(UnknownFunc(idx))
          }
        })
      }
      _, _, _ -> Error(Unsupported("element segment (Phase 5 surface)"))
    }
  })
}

/// Every active data segment's offset is an `i32` constant expression (spec
/// `valid/modules` data). `Error(NonConstantExpr)`/`Error(TypeMismatch)`. (Memory
/// presence is enforced when the segment is instantiated; the offset's i32-ness is
/// the static rule here.)
fn check_data(data: List(ast.DataSegment)) -> Result(Nil, ValidateError) {
  list.try_each(data, fn(d) {
    // Phase-2 case: an active segment at memory 0. Passive data and
    // active-with-explicit-memidx are P5-04's — rejected fail-closed here.
    case d.mode {
      ast.DataActive(0, offset) -> validate_const_expr(offset, ast.I32)
      _ -> Error(Unsupported("data segment (Phase 5 surface)"))
    }
  })
}

/// If a `start` function is present, its funcidx is in range and its type is `[] -> []`
/// (spec `valid/modules` start). `Error(UnknownFunc(_))`/`Error(BadStartType)`.
fn check_start(
  module: Module,
  func_types: List(FuncType),
) -> Result(Nil, ValidateError) {
  case module.start {
    option.None -> Ok(Nil)
    option.Some(idx) ->
      case nth(func_types, idx) {
        Error(_) -> Error(UnknownFunc(idx))
        Ok(ast.FuncType(params, results)) ->
          case params == [] && results == [] {
            True -> Ok(Nil)
            False -> Error(BadStartType)
          }
      }
  }
}

// ─────────────────────────────── numeric typing tables ───────────────────────────────

/// Type-check a numeric / comparison / conversion / float leaf instruction by its
/// fixed operand→result signature (spec: the numeric typing rules). Every Phase-1 and
/// Phase-2 numeric leaf has an explicit arm in `numeric_sig`; this just applies it.
fn validate_numeric(st: VState, instr: Instr) -> Result(VState, ValidateError) {
  let #(ins, outs) = numeric_sig(instr)
  use st2 <- result.try(pop_vals(st, ins))
  Ok(push_vals(st2, outs))
}

/// The `#(operands, results)` signature of every numeric/comparison/conversion/float
/// leaf opcode. Integer binary ops take two same-width operands and yield one;
/// comparisons yield `i32`; `eqz`/unary keep one operand; sign-extension and the two
/// truncation families follow their spec source/target widths; the float arith/unary/
/// copysign ops are width-preserving and the float comparisons yield `i32`; the
/// `0xA7–0xBF` conversion block is width-only (trapping vs. saturating is a runtime
/// concern with identical signatures).
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
    // saturating float→int truncation (0xFC 0..7)
    ast.I32TruncSatF32S -> #([f32], [i32])
    ast.I32TruncSatF32U -> #([f32], [i32])
    ast.I32TruncSatF64S -> #([f64], [i32])
    ast.I32TruncSatF64U -> #([f64], [i32])
    ast.I64TruncSatF32S -> #([f32], [i64])
    ast.I64TruncSatF32U -> #([f32], [i64])
    ast.I64TruncSatF64S -> #([f64], [i64])
    ast.I64TruncSatF64U -> #([f64], [i64])
    // f32 comparisons (yield i32)
    ast.F32Eq -> #([f32, f32], [i32])
    ast.F32Ne -> #([f32, f32], [i32])
    ast.F32Lt -> #([f32, f32], [i32])
    ast.F32Gt -> #([f32, f32], [i32])
    ast.F32Le -> #([f32, f32], [i32])
    ast.F32Ge -> #([f32, f32], [i32])
    // f64 comparisons (yield i32)
    ast.F64Eq -> #([f64, f64], [i32])
    ast.F64Ne -> #([f64, f64], [i32])
    ast.F64Lt -> #([f64, f64], [i32])
    ast.F64Gt -> #([f64, f64], [i32])
    ast.F64Le -> #([f64, f64], [i32])
    ast.F64Ge -> #([f64, f64], [i32])
    // f32 unary (width-preserving)
    ast.F32Abs -> #([f32], [f32])
    ast.F32Neg -> #([f32], [f32])
    ast.F32Ceil -> #([f32], [f32])
    ast.F32Floor -> #([f32], [f32])
    ast.F32Trunc -> #([f32], [f32])
    ast.F32Nearest -> #([f32], [f32])
    ast.F32Sqrt -> #([f32], [f32])
    // f32 binary (width-preserving, incl. copysign)
    ast.F32Add -> #([f32, f32], [f32])
    ast.F32Sub -> #([f32, f32], [f32])
    ast.F32Mul -> #([f32, f32], [f32])
    ast.F32Div -> #([f32, f32], [f32])
    ast.F32Min -> #([f32, f32], [f32])
    ast.F32Max -> #([f32, f32], [f32])
    ast.F32Copysign -> #([f32, f32], [f32])
    // f64 unary (width-preserving)
    ast.F64Abs -> #([f64], [f64])
    ast.F64Neg -> #([f64], [f64])
    ast.F64Ceil -> #([f64], [f64])
    ast.F64Floor -> #([f64], [f64])
    ast.F64Trunc -> #([f64], [f64])
    ast.F64Nearest -> #([f64], [f64])
    ast.F64Sqrt -> #([f64], [f64])
    // f64 binary (width-preserving, incl. copysign)
    ast.F64Add -> #([f64, f64], [f64])
    ast.F64Sub -> #([f64, f64], [f64])
    ast.F64Mul -> #([f64, f64], [f64])
    ast.F64Div -> #([f64, f64], [f64])
    ast.F64Min -> #([f64, f64], [f64])
    ast.F64Max -> #([f64, f64], [f64])
    ast.F64Copysign -> #([f64, f64], [f64])
    // int↔float conversion block (0xA7..0xBF) — width-only
    ast.I32WrapI64 -> #([i64], [i32])
    ast.I32TruncF32S -> #([f32], [i32])
    ast.I32TruncF32U -> #([f32], [i32])
    ast.I32TruncF64S -> #([f64], [i32])
    ast.I32TruncF64U -> #([f64], [i32])
    ast.I64ExtendI32S -> #([i32], [i64])
    ast.I64ExtendI32U -> #([i32], [i64])
    ast.I64TruncF32S -> #([f32], [i64])
    ast.I64TruncF32U -> #([f32], [i64])
    ast.I64TruncF64S -> #([f64], [i64])
    ast.I64TruncF64U -> #([f64], [i64])
    ast.F32ConvertI32S -> #([i32], [f32])
    ast.F32ConvertI32U -> #([i32], [f32])
    ast.F32ConvertI64S -> #([i64], [f32])
    ast.F32ConvertI64U -> #([i64], [f32])
    ast.F32DemoteF64 -> #([f64], [f32])
    ast.F64ConvertI32S -> #([i32], [f64])
    ast.F64ConvertI32U -> #([i32], [f64])
    ast.F64ConvertI64S -> #([i64], [f64])
    ast.F64ConvertI64U -> #([i64], [f64])
    ast.F64PromoteF32 -> #([f32], [f64])
    ast.I32ReinterpretF32 -> #([f32], [i32])
    ast.I64ReinterpretF64 -> #([f64], [i64])
    ast.F32ReinterpretI32 -> #([i32], [f32])
    ast.F64ReinterpretI64 -> #([i64], [f64])
    // Non-numeric instructions are handled by `validate_instr`; treat any other as
    // a no-op signature so this function stays total (unreachable in practice — every
    // numeric/conversion/float leaf has an explicit arm above).
    _ -> #([], [])
  }
}
