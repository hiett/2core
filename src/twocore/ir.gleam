//// The shared, language-neutral intermediate representation — the keystone of 2core.
////
//// A frontend lowers *into* this IR; the middle-end transforms it; the backend
//// (`emit_core`) emits Core Erlang from it. The IR is **structured, functional,
//// administrative normal form (ANF)**: computation is sequenced by `Let`, operands
//// are always atomic `Value`s, and structured control (`Block`/`Loop`/`If`/`Switch`)
//// composes as ordinary expressions. This shape lowers 1:1 onto Core Erlang
//// `let`/`letrec`/`case` + tail calls (see unit 08).
////
//// See `specs/phase-1/00-overview.md` (decisions D5/D6) and the high-level spec §3.
//// The canonical textual form is `specs/phase-1/ir-grammar.md` (the `.ir` grammar,
//// frozen together with these types — D7).
////
//// ## Design decisions baked into these types
////
//// - **D5 — three orthogonal capability axes.** A `Module` declares them
////   independently and never fuses them: the *term* layer (BEAM-native values) is
////   always available; *fixed-width numerics* (`i32/i64/f32/f64`) are opt-in via
////   `uses_numerics`; *linear memory* is a **separate** opt-in via `memory`
////   (`Option(MemoryDecl)`). A numerics-only module sets `memory: None` so it links
////   no memory runtime. Conversions between the term and numeric layers are
////   **explicit IR ops** (`Convert` with a boxing `ConvOp`) — there is no implicit
////   bridging.
//// - **D5 — floats are bit patterns.** Float constants store the **raw IEEE-754 bit
////   pattern** (in an `Int`), never a native BEAM double, because BEAM doubles cannot
////   represent NaN/Infinity. Integer constants store the **raw unsigned bit pattern**
////   in `[0, 2^width)`.
//// - **D6 — IR neutrality.** Operation names are neutral and width-tagged
////   (`IAdd(W32)`, not the WASM opcode string `"i32.add"`). Structured control
////   references **named labels only** — never a numeric branch depth (the WASM
////   frontend resolves `br N` into a named label at the frontend boundary). There is
////   **no operand-stack typing** in the IR; the frontend has already eliminated the
////   stack into named values.
////
//// ## Resolved open questions (unit 01 freeze)
////
//// 1. **Names, not SSA indices.** Locals, params, let-bindings, loop vars, and labels
////    are `String` names (clearer `.ir`, easier debugging). They must be **unique
////    within a function**; the backend alpha-renames to Core Erlang's variable rules,
////    so IR names need only be unique, not Core-legal. The WASM frontend conventionally
////    names params `p0 … p{n-1}` so the `.ir` text and body references line up.
//// 2. **`If` condition is an i32 truth value.** `If.cond` is a `Value` interpreted as
////    an i32 (`0` = false, non-zero = true); the emitter tests `≠ 0`. A future term
////    frontend boxes its condition to an i32; no term-boolean is baked into `If`.
//// 3. **Trapping ops keep the `Expr` clean.** A `Num(IDivS(..), ..)` *yields a value*
////    in the IR. The trap is realised entirely by `emit_core` + `rt_num`'s
////    `Result(Int, TrapReason)`-returning signatures (the emitter `case`s on the
////    result and raises on `Error`). The IR `Expr` type carries no `Result`.
//// 4. **Block/Loop results thread through `Let`.** A block's result list can be bound:
////    `Let(["x"], Block("b", [TI32], ..), body)`. The three Phase-1 acceptance
////    programs (`add`, `sum_to`, `fib`) lower cleanly under this shape — see
////    `test/twocore/ir/strawman_test.gleam`.

import gleam/list
import gleam/option.{type Option}

// ───────────────────────── Module & declarations ─────────────────────────

/// A compilation unit — the top-level IR object that the whole pipeline carries.
///
/// The three capability axes (D5) are independent and never fused:
/// - `uses_numerics`: whether the module uses the low-level `i32/i64/f32/f64` layer.
/// - `memory`: linear memory is opt-in and **separate** from numerics. `None` means
///   the module links no memory runtime; `Some(MemoryDecl)` declares its sizing.
/// - the term layer is always available (no flag).
///
/// A Phase-1 WASM module sets `uses_numerics: True` and `memory: None`.
///
/// Fields:
/// - `name`: the module's logical name (becomes part of the emitted module name).
/// - `globals`: module-level mutable/immutable global slots.
/// - `imports`: host functions reachable only through `CallHost` (the capability
///   boundary).
/// - `functions`: the module's own defined functions.
/// - `exports`: the externally callable entry points (export-name → function name).
/// - `data_segments`: Phase-2 linear-memory initialisers (active segments written into
///   memory at instantiation).
/// - `tables`: the module's funcref tables (Phase-2; MVP funcref-only). A `CallIndirect`
///   references one of these by name.
/// - `elements`: active element segments — funcrefs written into a `tables` entry at
///   instantiation (an out-of-bounds active segment traps at instantiation).
/// - `start`: the name of the module's start function (run once at instantiation), or
///   `None`. A trapping start fails instantiation.
pub type Module {
  Module(
    name: String,
    uses_numerics: Bool,
    memory: Option(MemoryDecl),
    globals: List(GlobalDecl),
    imports: List(ImportDecl),
    functions: List(Function),
    exports: List(ExportDecl),
    data_segments: List(DataSegment),
    tables: List(TableDecl),
    elements: List(ElementSegment),
    start: Option(String),
  )
}

/// A funcref table declaration (Phase-2). The MVP's only reference type is `funcref`, so a
/// table is described purely by its sizing.
///
/// - `name`: the table's unique name (referenced by `CallIndirect` and `ElementSegment`).
/// - `min`: the initial size in entries (≥ 0). Every slot starts uninitialised (null).
/// - `max`: optional upper bound in entries; `None` means unbounded growth (table growth
///   itself is a post-MVP op — Phase-2 only populates a table via element segments).
pub type TableDecl {
  TableDecl(name: String, min: Int, max: Option(Int))
}

/// An ACTIVE element segment (Phase-2): at instantiation, write `funcs` (each a defined
/// IR function name) into the named `table` starting at the constant `offset`.
///
/// - `table`: the target table's name (must match a `TableDecl.name`).
/// - `offset`: a constant expression giving the first entry index written. An offset (or
///   offset+len) past the table bound traps at instantiation (`TableOutOfBounds`).
/// - `funcs`: the IR function names placed into consecutive entries from `offset`. Each
///   becomes a build-controlled type-tagged closure (never a data-driven `apply`).
pub type ElementSegment {
  ElementSegment(table: String, offset: Expr, funcs: List(String))
}

/// Declares the module's single linear memory (Phase-2 subsystem; modelled now per
/// D5 lock-now).
///
/// - `min_pages`: initial size in 64 KiB WebAssembly pages (≥ 0).
/// - `max_pages`: optional upper bound in pages; `None` means unbounded growth.
pub type MemoryDecl {
  MemoryDecl(min_pages: Int, max_pages: Option(Int))
}

/// A module-level global variable slot.
///
/// - `name`: unique global name (referenced by `GlobalGet`/`GlobalSet`).
/// - `ty`: the global's value type.
/// - `mutable`: whether `GlobalSet` is permitted; immutable globals are write-once at
///   init.
/// - `init`: the constant initialiser expression evaluated at instantiation.
pub type GlobalDecl {
  GlobalDecl(name: String, ty: ValType, mutable: Bool, init: Expr)
}

/// An imported host function — the ONLY thing reachable from a body via `CallHost`
/// (the capability boundary, high-level §6).
///
/// - `capability`: groups imports for the host policy (e.g. deny-all checks this).
/// - `name`: the imported function's name within the capability.
/// - `ty`: the nameless signature the import is expected to satisfy.
pub type ImportDecl {
  ImportFn(capability: String, name: String, ty: FuncType)
}

/// Names an externally callable entry point.
///
/// - `export_name`: the name the outside world calls (an arbitrary string).
/// - `fn_name`: the name of the `Function` it resolves to within this module.
pub type ExportDecl {
  ExportFn(export_name: String, fn_name: String)
}

/// An ACTIVE linear-memory data initialiser (Phase-2): write `bytes` into linear memory at
/// `offset` during instantiation. An out-of-bounds segment traps at instantiation (reusing
/// `MemoryOutOfBounds`).
///
/// - `offset`: a constant expression giving the byte offset at which `bytes` are
///   written.
/// - `bytes`: the raw bytes to write into linear memory at instantiation.
pub type DataSegment {
  DataSegment(offset: Expr, bytes: BitArray)
}

// ───────────────────────────── Types ─────────────────────────────

/// The bit-width of a low-level integer operation: 32 or 64 bits.
pub type IntWidth {
  W32
  W64
}

/// The bit-width of a low-level float operation: 32-bit (`FW32`) or 64-bit (`FW64`).
pub type FloatWidth {
  FW32
  FW64
}

/// A value's type. The low-level numeric types and the boxed term type coexist (D5);
/// conversions between the layers are always explicit (`Convert` with a boxing
/// `ConvOp`).
///
/// - `TI32`/`TI64`: 32/64-bit integers (stored as raw unsigned bit patterns).
/// - `TF32`/`TF64`: 32/64-bit floats (stored as raw IEEE-754 bit patterns).
/// - `TTerm`: a boxed BEAM term (atoms/tuples/lists/… — the home of Phase-2 term
///   frontends).
pub type ValType {
  TI32
  TI64
  TF32
  TF64
  TTerm
}

/// A nameless function signature: the parameter types and the result types.
///
/// Used where names are irrelevant — imports and `call_indirect` type tags. A defined
/// `Function`'s signature is *derived* from its named params via `signature/1` rather
/// than stored, so names and types cannot drift.
pub type FuncType {
  FuncType(params: List(ValType), results: List(ValType))
}

// ───────────────────────────── Functions ─────────────────────────────

/// A function in ANF-with-structured-control.
///
/// Params and locals are NAMED, typed slots — the frontend has already eliminated any
/// operand stack into named values (high-level §8.1).
///
/// Fields:
/// - `name`: the function's unique name within the module.
/// - `params`: named argument slots, in order. Their names let the `.ir` text and the
///   body reference arguments (e.g. `%p0`). The nameless `FuncType` is derived from
///   these via `signature/1`, never stored separately.
/// - `result`: the result types the body yields (0, 1, or many — multi-value).
/// - `locals`: additional named slots used by the body (distinct from `params`).
/// - `body`: the expression whose evaluation produces the function's `result` values
///   (via a `Return`, or a fall-through expression of the right arity).
///
/// All names across `params`, `locals`, and let-bindings/labels must be unique within
/// the function (resolved open question #1).
pub type Function {
  Function(
    name: String,
    params: List(Local),
    result: List(ValType),
    locals: List(Local),
    body: Expr,
  )
}

/// A named, typed value slot (a parameter or a local).
///
/// - `name`: the slot's name, unique within its function.
/// - `ty`: the slot's value type.
pub type Local {
  Local(name: String, ty: ValType)
}

/// Derives the nameless `FuncType` of a defined function from its named params and
/// declared results.
///
/// This is the single source of truth for a function's signature: it is computed from
/// `f.params`/`f.result` rather than stored, so the names and the type can never drift
/// (resolved open question #1). Imports and `call_indirect` use a `FuncType` directly
/// since they have no named params.
///
/// Returns the `FuncType` whose `params` are the param slots' types (in order) and
/// whose `results` are `f.result`. Total — never fails.
pub fn signature(f: Function) -> FuncType {
  FuncType(params: list.map(f.params, fn(l) { l.ty }), results: f.result)
}

// ───────────────────────────── Values ─────────────────────────────

/// An atomic value operand: either a reference to a named binding or an immediate
/// constant. In ANF every operand position holds a `Value`, never a nested
/// computation.
///
/// - `Var(name)`: references a param, local, or let-bound name in scope.
/// - `ConstI32(bits)`/`ConstI64(bits)`: an integer constant stored as its RAW UNSIGNED
///   bit pattern in `[0, 2^width)`.
/// - `ConstF32(bits)`/`ConstF64(bits)`: a float constant stored as its RAW IEEE-754
///   bit pattern in an `Int` (D5 — never a BEAM double, so NaN/Inf/`-0.0` are exact).
pub type Value {
  Var(name: String)
  ConstI32(bits: Int)
  ConstI64(bits: Int)
  ConstF32(bits: Int)
  ConstF64(bits: Int)
}

// ───────────────────── Expressions (yield value lists) ─────────────────────

/// An expression. Every expression yields a list of 0, 1, or many values
/// (multi-value). Structured-control constructs are expressions too, so they compose
/// under `Let`. The non-returning transfers (`Break`/`Continue`/`Return`/`Trap`) do
/// not fall through — their "result type" is bottom.
///
/// This is administrative normal form: `Let(names, rhs, body)` sequences computation,
/// operands are atomic `Value`s, and the leaves are pure/trapping ops or calls. It
/// maps 1:1 onto Core Erlang `let`/`letrec`/`case` + tail calls (unit 08).
///
/// Variants:
/// - `Values(vs)`: forward existing values unchanged (e.g. a block's tail result).
/// - `Num(op, args)`: a low-level numeric op (neutral, width-tagged — D6). Trapping
///   variants (e.g. `IDivS`) still *yield a value* here; the emitter realises the trap
///   via `rt_num`'s `Result` (resolved open question #3).
/// - `Convert(op, arg)`: a width/sign/layer conversion, including explicit
///   term↔numeric boxing (the only bridge between the value layers, D5).
/// - `TermOp(op, args)`: term construction/destructuring (Phase-2 term layer;
///   lock-now placeholder).
/// - `MemSize`/`MemGrow(delta)`: query / grow linear memory (`memory.size` returns the
///   page count; `memory.grow` returns the previous page count or `-1`).
/// - `MemLoad`/`MemStore`: typed linear-memory access with a static `offset` (Phase-2).
///   `MemLoad` carries a `result` value type (a load's result bit pattern depends on its
///   target width/sign, which `MemAccess` alone cannot express).
/// - `GlobalGet(name)`/`GlobalSet(name, value)`: read/write a module global.
/// - `CallDirect`/`CallIndirect`/`CallHost`: the three first-class call kinds
///   (high-level §3). `CallHost` is THE capability boundary.
/// - `Let(names, rhs, body)`: bind `rhs`'s result values to `names`, then evaluate
///   `body`. The arity of `names` matches the arity of `rhs`'s results.
/// - `Block`/`Loop`/`If`/`Switch`: structured control with **named labels only** (D6).
/// - `Break`/`Continue`/`Return`: non-returning control transfers.
/// - `Trap(reason)`: abort with a typed trap.
/// - `Charge(cost, body)`: the metering hook — charge `cost` fuel, then evaluate
///   `body` (inserted by `ir_lower`, unit 11; D9).
///
/// **Effects (E6).** `MemLoad`, `MemStore`, `MemGrow`, `GlobalGet`, `GlobalSet`, and
/// `CallIndirect` are **side-effecting**: they read and/or write mutable instance state
/// (the per-instance memory/globals/table cell). A future optimizer must treat them as
/// memory barriers — **no** CSE of a load across a store, **no** reordering across a grow,
/// **no** dead-store elimination without an aliasing proof. The remaining `Expr` variants
/// (`Num`/`Convert`/`Values`/structured control/…) are pure. `CallHost` and `Charge` are
/// effectful by their nature (host boundary / fuel) and likewise non-reorderable.
pub type Expr {
  // pure / value-producing ----------------------------------------------------
  /// Forward existing values unchanged (e.g. a block's tail result).
  Values(List(Value))
  /// A low-level numeric op (neutral, width-tagged — D6). Trapping variants yield a
  /// value here; `emit_core` + `rt_num` realise the trap (open question #3).
  Num(op: NumOp, args: List(Value))
  /// Width / sign / layer conversions, including explicit term↔numeric boxing.
  Convert(op: ConvOp, arg: Value)
  /// Term construction / destructuring (Phase-2 term layer; lock-now placeholder).
  TermOp(op: TermOp, args: List(Value))
  // linear-memory layer (Phase-2) --------------------------------------------
  /// `memory.size` → the current linear-memory size in 64 KiB pages (an i32).
  /// Side-effecting (observes mutable state; do not CSE across a `MemGrow`).
  MemSize
  /// `memory.grow(delta_pages)` → the PREVIOUS size in pages, or `-1` (i32) on failure
  /// (the requested growth exceeds the declared `max_pages` or the Safe max-pages cap).
  /// Side-effecting (E6): allocates/zero-fills pages and mutates the memory state.
  MemGrow(delta: Value)
  /// Typed load from linear memory at `addr + offset`, yielding a `result`-typed value.
  ///
  /// `op` (a `MemAccess`) carries the access width in bytes and, for sub-word loads, the
  /// sign-extension flag. `result` is the value type the load PRODUCES — it is required
  /// because `op` alone cannot distinguish `i32.load8_s` from `i64.load8_s` (identical
  /// bytes + sign, different result bit pattern). Side-effecting (E6).
  MemLoad(op: MemAccess, addr: Value, offset: Int, result: ValType)
  /// Typed store of `value` to linear memory at `addr + offset`. `op.bytes` is the store
  /// width; `op.signed` is IRRELEVANT for stores (a store writes the low `bytes` bytes of
  /// `value` regardless of sign) and is ignored. Side-effecting (E6); the evaluation order
  /// is addr, then value, then the store.
  MemStore(op: MemAccess, addr: Value, value: Value, offset: Int)
  /// Read the named module global's current value.
  GlobalGet(name: String)
  /// Write `value` into the named (mutable) module global.
  GlobalSet(name: String, value: Value)
  // calls (three kinds, all first-class — high-level §3) ----------------------
  /// A direct call to a same-module function by name.
  CallDirect(fn_name: String, args: List(Value))
  /// An indirect call through `table` at `index`, type-checked against `ty`.
  CallIndirect(table: String, index: Value, ty: FuncType, args: List(Value))
  /// THE capability boundary. Both host imports and `own` stdlib lower to this
  /// (high-level §6); `ir_lower` (unit 11) decides each one's fate.
  CallHost(capability: String, name: String, args: List(Value))
  // sequencing ----------------------------------------------------------------
  /// Bind `rhs`'s result values to `names`, then evaluate `body`.
  Let(names: List(String), rhs: Expr, body: Expr)
  // structured control (named labels only — D6) -------------------------------
  /// Forward block. Falling off the end yields `result` values; `Break(label, vs)`
  /// jumps to just after this block with `vs`.
  Block(label: String, result: List(ValType), body: Expr)
  /// Loop carrying named iteration vars. `Continue(label, vs)` re-enters the head
  /// rebinding `params`; `Break(label, vs)` (or fall-through) exits with `result`.
  Loop(
    label: String,
    params: List(LoopParam),
    result: List(ValType),
    body: Expr,
  )
  /// Two-way branch. `cond` is an i32 truth value (`0` = false). Both arms yield
  /// `result`.
  If(cond: Value, result: List(ValType), then_branch: Expr, else_branch: Expr)
  /// Multi-way switch on an integer selector with a mandatory `default` arm. Both the
  /// arms and the default yield `result`.
  Switch(
    selector: Value,
    result: List(ValType),
    arms: List(SwitchArm),
    default: Expr,
  )
  // non-returning control transfers -------------------------------------------
  /// Exit the enclosing block/loop named `label`, yielding `values`.
  Break(label: String, values: List(Value))
  /// Re-enter the enclosing loop named `label`, rebinding its params to `values`.
  Continue(label: String, values: List(Value))
  /// Return `values` from the enclosing function.
  Return(values: List(Value))
  // effects -------------------------------------------------------------------
  /// Abort execution with a typed trap reason (lowered to an `rt_trap` raise).
  Trap(reason: TrapReason)
  /// Metering hook (D9): charge `cost` fuel, then evaluate `body`. Inserted by
  /// `ir_lower` (unit 11).
  Charge(cost: Int, body: Expr)
}

/// A named loop iteration variable with its initial value.
///
/// - `name`: the loop var's name, in scope within the loop body.
/// - `ty`: its value type.
/// - `init`: the value bound on first entry (re-bound by `Continue` thereafter).
pub type LoopParam {
  LoopParam(name: String, ty: ValType, init: Value)
}

/// One arm of a `Switch`: when the selector equals `match`, evaluate `body`.
pub type SwitchArm {
  SwitchArm(match: Int, body: Expr)
}

// ───────────────────────────── Operations ─────────────────────────────

/// Neutral, width-tagged numeric operations (D6 — never WASM opcode strings).
///
/// `emit_core` maps each constructor to a concrete `rt_num` function name (the binding
/// chokepoint, units 06/08). Signed vs unsigned is a fundamental low-level distinction
/// (cf. LLVM `sdiv`/`udiv`), not a WASM-ism. Integer ops take/produce raw unsigned bit
/// patterns; the comparison ops (`IEq` … `IGeU`, `IEqz`) produce an i32 truth value
/// (`0` or `1`). The four `IDivS`/`IDivU`/`IRemS`/`IRemU` are the trapping ops (open
/// question #3). Float ops operate on raw IEEE-754 bit patterns.
pub type NumOp {
  IAdd(IntWidth)
  ISub(IntWidth)
  IMul(IntWidth)
  IDivS(IntWidth)
  IDivU(IntWidth)
  IRemS(IntWidth)
  IRemU(IntWidth)
  IAnd(IntWidth)
  IOr(IntWidth)
  IXor(IntWidth)
  IShl(IntWidth)
  IShrS(IntWidth)
  IShrU(IntWidth)
  IRotl(IntWidth)
  IRotr(IntWidth)
  IClz(IntWidth)
  ICtz(IntWidth)
  IPopcnt(IntWidth)
  IEqz(IntWidth)
  IEq(IntWidth)
  INe(IntWidth)
  ILtS(IntWidth)
  ILtU(IntWidth)
  IGtS(IntWidth)
  IGtU(IntWidth)
  ILeS(IntWidth)
  ILeU(IntWidth)
  IGeS(IntWidth)
  IGeU(IntWidth)
  // floats — binary arithmetic (Phase-1 covered these end-to-end; see unit 06)
  FAdd(FloatWidth)
  FSub(FloatWidth)
  FMul(FloatWidth)
  FDiv(FloatWidth)
  FMin(FloatWidth)
  FMax(FloatWidth)
  // floats — unary (Phase-2). Operate on / produce raw IEEE-754 bit patterns.
  /// `f.abs` — clear the sign bit (magnitude).
  FAbs(FloatWidth)
  /// `f.neg` — flip the sign bit.
  FNeg(FloatWidth)
  /// `f.ceil` — round toward +∞.
  FCeil(FloatWidth)
  /// `f.floor` — round toward −∞.
  FFloor(FloatWidth)
  /// `f.trunc` — round toward zero.
  FTrunc(FloatWidth)
  /// `f.nearest` — round to nearest, ties to even.
  FNearest(FloatWidth)
  /// `f.sqrt` — IEEE square root.
  FSqrt(FloatWidth)
  /// `f.copysign(a, b)` — magnitude of `a` with the sign of `b`.
  FCopysign(FloatWidth)
  // floats — comparisons (Phase-2). Produce an i32 truth value (`0`/`1`).
  /// `f.eq` — ordered equality (NaN compares false).
  FEq(FloatWidth)
  /// `f.ne` — ordered/unordered inequality (NaN compares true).
  FNe(FloatWidth)
  /// `f.lt` — ordered less-than.
  FLt(FloatWidth)
  /// `f.gt` — ordered greater-than.
  FGt(FloatWidth)
  /// `f.le` — ordered less-than-or-equal.
  FLe(FloatWidth)
  /// `f.ge` — ordered greater-than-or-equal.
  FGe(FloatWidth)
}

/// Conversion operations: width/sign changes within the numeric layer, float↔int
/// reinterpretation/truncation, and the explicit term↔numeric boxing bridge (D5).
///
/// - `I32WrapI64`: narrow an i64 to its low 32 bits.
/// - `I64ExtendI32S`/`I64ExtendI32U`: widen an i32 to i64 (sign- or zero-extended).
/// - `I32Extend8S`/`I32Extend16S`/`I64Extend8S`/`I64Extend16S`/`I64Extend32S`:
///   sign-extend a sub-word value within the same width.
/// - `TruncSatS(from, to)`/`TruncSatU(from, to)`: saturating float→int truncation
///   (never traps).
/// - `ReinterpretFToI(w)`/`ReinterpretIToF(w)`: reinterpret the raw bit pattern
///   between a float and an integer of the same width (no value change).
/// - `BoxInt`/`UnboxInt`/`BoxFloat`/`UnboxFloat`: the ONLY bridge between the term
///   layer and the numeric layer (D5) — explicit, never implicit.
/// - `TruncS(from, to)`/`TruncU(from, to)`: TRAPPING float→int truncation (Phase-2),
///   distinct from the saturating `TruncSat*` — traps on NaN/±Inf
///   (`InvalidConversionToInteger`) or out-of-range (`IntOverflow`).
/// - `ConvertS(from, to)`/`ConvertU(from, to)`: int→float conversion (round to nearest,
///   ties to even). Never traps.
/// - `F32DemoteF64`/`F64PromoteF32`: float width changes (narrow f64→f32 with rounding;
///   widen f32→f64 exactly).
pub type ConvOp {
  I32WrapI64
  I64ExtendI32S
  I64ExtendI32U
  I32Extend8S
  I32Extend16S
  I64Extend8S
  I64Extend16S
  I64Extend32S
  TruncSatS(from: FloatWidth, to: IntWidth)
  TruncSatU(from: FloatWidth, to: IntWidth)
  ReinterpretFToI(FloatWidth)
  ReinterpretIToF(IntWidth)
  // explicit term↔numeric boxing (D5) — the only bridge between the layers
  BoxInt(IntWidth)
  UnboxInt(IntWidth)
  BoxFloat(FloatWidth)
  UnboxFloat(FloatWidth)
  // TRAPPING float→int truncation (Phase-2) — distinct from the saturating `TruncSat*`.
  // Traps `InvalidConversionToInteger` on NaN/±Inf and `IntOverflow` when the truncated
  // value is out of the target's range; otherwise truncates toward zero. Because they
  // trap, `emit_core` wires these through `rt_num`'s `Result(Int, TrapReason)` signatures
  // (the `case`-and-`raise` shape), unlike the total `TruncSat*`.
  /// Trapping signed truncation `from` float → `to` int.
  TruncS(from: FloatWidth, to: IntWidth)
  /// Trapping unsigned truncation `from` float → `to` int.
  TruncU(from: FloatWidth, to: IntWidth)
  // int→float conversion (Phase-2) — round to nearest, ties to even. Never traps.
  /// Signed `from` int → `to` float.
  ConvertS(from: IntWidth, to: FloatWidth)
  /// Unsigned `from` int → `to` float.
  ConvertU(from: IntWidth, to: FloatWidth)
  /// `f32.demote_f64` — narrow an f64 to f32 (round to nearest, ties to even).
  F32DemoteF64
  /// `f64.promote_f32` — widen an f32 to f64 (exact).
  F64PromoteF32
}

/// Term-layer operations (Phase-2; lock-now placeholder so the term frontends do not
/// retrofit the IR). Extended in Phase 2.
///
/// - `MakeTuple`: build a tuple from its argument values.
/// - `TupleGet(index)`: project the element at `index` from a tuple.
/// - `MakeCons`: build a list cons cell (head, tail).
pub type TermOp {
  MakeTuple
  TupleGet(index: Int)
  MakeCons
  // … extend in Phase 2
}

/// Describes a linear-memory access (Phase-2; lock-now).
///
/// - `bytes`: the access width in bytes (1/2/4/8).
/// - `signed`: for sub-word loads, whether the loaded value is sign-extended.
pub type MemAccess {
  MemAccess(bytes: Int, signed: Bool)
}

/// The reason an execution `Trap`s. Lowered to a concrete `rt_trap` raise by the
/// emitter.
///
/// - `IntDivByZero`: integer divide/remainder by zero.
/// - `IntOverflow`: signed `div_s` of `INT_MIN / -1` (the one overflow trap).
/// - `Unreachable`: an explicit unreachable point was executed.
/// - `IndirectCallTypeMismatch`: a `CallIndirect` target's type did not match.
/// - `MemoryOutOfBounds`: a linear-memory access fell outside bounds. Also raised when an
///   active DATA segment is out of bounds at instantiation.
/// - `InvalidConversionToInteger`: a trapping float→int truncation of NaN or ±Inf
///   (distinct from `IntOverflow`, which is the out-of-range case).
/// - `UndefinedElement`: a `CallIndirect` whose table index is out of bounds (runtime).
/// - `UninitializedElement`: a `CallIndirect` to a null / unfilled table slot.
/// - `TableOutOfBounds`: an active ELEMENT segment is out of bounds at instantiation.
/// - `FuelExhausted`: the 2core CPU-fuel resource bound was exhausted (Phase-3, F5). This is
///   OUR policy trap, NOT a WebAssembly spec trap — no `.wasm` operation raises it and no
///   `assert_trap` expects it. It is a **runtime** reason raised only by `rt_meter.charge`
///   when a seeded budget is spent, and is **never emitted as an IR `Trap` node** (no lowering
///   produces `Trap(FuelExhausted)`); it lives in `TrapReason` only so it rides the existing
///   catchable `{wasm_trap, Kind}` channel and surfaces through the run-ABI as an ordinary
///   `Trapped(reason)`.
pub type TrapReason {
  IntDivByZero
  IntOverflow
  Unreachable
  IndirectCallTypeMismatch
  MemoryOutOfBounds
  InvalidConversionToInteger
  UndefinedElement
  UninitializedElement
  TableOutOfBounds
  FuelExhausted
}
