# Unit 01 — Interface Freeze (Wave 0, the dual keystone)

> **One owner. ~1 day. Design + compiling stubs only — no algorithms.** This unit is
> on the critical path of *everything*. Its job is to publish the cross-cutting types
> the swarm targets, so that "freeze the interface, then parallelize the
> implementations" (D1) actually happens. Read [`00-overview.md`](00-overview.md)
> first; this doc assumes D1–D10.

There are **two keystones**, equally load-bearing: **(1) the IR** and **(2) the runtime
binding / calling convention**. Both are frozen here, by one person, because they
interrelate — `emit_core` (`08`) targets both at once.

---

## Goal

Land compiling-but-empty stub modules + a grammar doc + a neutrality sign-off, and
announce the freeze milestones, so Wave A/B can begin. Deliverables:

1. `src/twocore/ir.gleam` — the **complete** IR type set (full high-level §3 surface,
   not just the Phase-1 subset). → milestone **«IR-FROZEN»**
2. `specs/phase-1/ir-grammar.md` — the `.ir` textual grammar (a strawman is already
   seeded; finalize it to match the frozen types).
3. `src/twocore/runtime/instance.gleam` — the `Binding` record + the documented
   calling convention + `safe_default()`. → milestone **«ABI-FROZEN»**
4. `src/twocore/runtime/rt_num.gleam` — the **signatures** of every Phase-1 numeric
   function, bodies = `todo`. → milestone **«RTNUM-SIG-FROZEN»** (then ownership of the
   file passes to unit `06`).
5. `src/twocore/pipeline.gleam` — the `PipelineError` sum (per-stage variants, D4) +
   stage type aliases, as stubs.
6. A small set of **hand-authored** golden `.ir` files under
   `test/twocore/ir/golden/` covering the **full** surface (so `02`'s round-trip locks
   more than the integer subset). These are written *by reading the grammar*, never
   generated.
7. The **neutrality review** checklist (below), signed off in `state.md`.

**Out of scope:** any printer, parser, decoder, emitter, or runtime *logic*. Bodies are
`todo`/placeholder. `gleam build` must compile with **no warnings** (a `todo` body
compiles; an unused import warns — keep it clean).

---

## Why complete-now, even though Phase-1 only exercises a subset

The IR is **frozen first** and is the keystone everything targets; anything you omit
now is the costly retrofit the high-level spec warns about (decisions #1/#2/#4). So the
type set must include — even though the Phase-1 corpus never exercises them — the
`call_host` node, the `trap` **and** `charge` effects, the **optional linear-memory**
subsystem (a module-level flag + typed load/store ops), the **dual value model** (term
layer + low-level numerics) **with explicit conversion ops**, and **global**
declarations. The `.ir` golden files (deliverable 6) must cover each, so `02`'s
round-trip protects the whole surface, not just integers.

---

## The IR — concrete strawman (refine, then freeze)

This is a **strawman to start from**, not gospel — but the *shape* is deliberate and
encodes D5 (three value axes; floats as bits), D6 (named labels, neutral ops), and the
backend's needs (this is **ANF with structured control**, which lowers 1:1 to Core
Erlang `let`/`letrec`/`case` — see `08`). Resolve the open questions (below), run the
neutrality review, then freeze.

```gleam
//// src/twocore/ir.gleam
//// The shared, language-neutral IR (the keystone). Structured, functional, ANF.
//// A frontend lowers INTO this; the middle-end transforms it; the backend emits
//// Core Erlang from it. See specs/phase-1/00-overview.md (D5/D6) and high-level §3.

import gleam/list
import gleam/option.{type Option}

// ───────────────────────── Module & declarations ─────────────────────────

/// A compilation unit. The three capability axes (D5) are independent:
/// `uses_numerics` (low-level i32/i64/f32/f64) and `memory` (linear memory) are each
/// opt-in; term values are always available. A Phase-1 WASM module sets
/// `uses_numerics: True` and `memory: None` (links no memory runtime).
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
  )
}

pub type MemoryDecl {
  MemoryDecl(min_pages: Int, max_pages: Option(Int))
}

pub type GlobalDecl {
  GlobalDecl(name: String, ty: ValType, mutable: Bool, init: Expr)
}

/// An imported host function. The ONLY way to reach it from a body is `CallHost`
/// (the capability boundary). `capability` groups imports for the host policy.
pub type ImportDecl {
  ImportFn(capability: String, name: String, ty: FuncType)
}

pub type ExportDecl {
  ExportFn(export_name: String, fn_name: String)
}

/// Phase-2; present for lock-now completeness. Initialises linear memory.
pub type DataSegment {
  DataSegment(offset: Expr, bytes: BitArray)
}

// ───────────────────────────── Types ─────────────────────────────

pub type IntWidth {
  W32
  W64
}

pub type FloatWidth {
  FW32
  FW64
}

/// A value's type. The low-level numeric types and the term type coexist (D5);
/// conversions between them are explicit (`Convert` with a boxing op).
pub type ValType {
  TI32
  TI64
  TF32
  TF64
  TTerm
  // a boxed BEAM term (Phase-2 frontends)
}

pub type FuncType {
  FuncType(params: List(ValType), results: List(ValType))
}

// ───────────────────────────── Functions ─────────────────────────────

/// A function in ANF-with-structured-control. Params and locals are NAMED, typed
/// slots — the frontend has already eliminated any operand stack into named values
/// (high-level §8.1). `params` give names to the function's argument slots (so the
/// `.ir` text and the body can reference them — e.g. `%p0`); `body` yields the
/// function's result list (a `Return`, or a fall-through of the right arity).
///
/// The signature `FuncType` is DERIVED from `params`/`result` via `signature/1`
/// (below) — it is not stored separately, so names and types can never drift. Imports
/// and `call_indirect` still use the nameless `FuncType`.
pub type Function {
  Function(
    name: String,
    params: List(Local),
    result: List(ValType),
    locals: List(Local),
    body: Expr,
  )
}

pub type Local {
  Local(name: String, ty: ValType)
}

/// The (nameless) type signature of a function, derived from its params and result.
pub fn signature(f: Function) -> FuncType {
  FuncType(params: list.map(f.params, fn(l) { l.ty }), results: f.result)
}

// ───────────────────────────── Values ─────────────────────────────

/// A value operand: a reference to a named binding (param / local / let-bound) or an
/// immediate constant. Integer constants store the RAW UNSIGNED bit pattern in
/// [0, 2^width). Float constants store the RAW IEEE-754 bit pattern (D5: never a BEAM
/// double).
pub type Value {
  Var(name: String)
  ConstI32(bits: Int)
  ConstI64(bits: Int)
  ConstF32(bits: Int)
  ConstF64(bits: Int)
}

// ───────────────────── Expressions (yield value lists) ─────────────────────

/// Every expression yields a list of 0, 1, or many values (multi-value). Structured
/// control constructs are expressions too, so they compose under `Let`. `Break` /
/// `Continue` / `Return` / `Trap` do not fall through (their "result type" is bottom).
///
/// This is administrative normal form: `Let(names, rhs, body)` sequences computation,
/// and the leaves are pure/trapping ops or calls. It maps 1:1 onto Core Erlang
/// `let`/`letrec`/`case` + tail calls (see unit 08).
pub type Expr {
  // pure / value-producing ----------------------------------------------------
  /// Forward existing values unchanged (e.g. a block's tail result).
  Values(List(Value))
  /// A low-level numeric op (neutral, width-tagged — D6). Trapping variants
  /// (e.g. IDivS) yield via the runtime's Result; the emitter raises (see 06/08).
  Num(op: NumOp, args: List(Value))
  /// Width / sign / layer conversions, incl. explicit term↔numeric boxing.
  Convert(op: ConvOp, arg: Value)
  /// Term construction / destructuring (Phase-2 term layer; lock-now placeholder).
  TermOp(op: TermOp, args: List(Value))
  // linear-memory layer (Phase-2; lock-now) ----------------------------------
  MemLoad(op: MemAccess, addr: Value, offset: Int)
  MemStore(op: MemAccess, addr: Value, value: Value, offset: Int)
  GlobalGet(name: String)
  GlobalSet(name: String, value: Value)
  // calls (three kinds, all first-class — high-level §3) ----------------------
  CallDirect(fn_name: String, args: List(Value))
  CallIndirect(table: String, index: Value, ty: FuncType, args: List(Value))
  /// THE capability boundary. Host imports AND stdlib both lower to this (high-level §6).
  CallHost(capability: String, name: String, args: List(Value))
  // sequencing ----------------------------------------------------------------
  /// Bind `rhs`'s results to `names`, then evaluate `body`.
  Let(names: List(String), rhs: Expr, body: Expr)
  // structured control (named labels only — D6) -------------------------------
  /// Forward block. Falling off the end yields `result` values; `Break(label, vs)`
  /// jumps to just after this block with `vs`.
  Block(label: String, result: List(ValType), body: Expr)
  /// Loop carrying named iteration vars. `Continue(label, vs)` re-enters the head
  /// rebinding `params`; `Break(label, vs)` (or fall-through) exits with `result`.
  Loop(label: String, params: List(LoopParam), result: List(ValType), body: Expr)
  /// `cond` is an i32 truth value (0 = false). Both arms yield `result`.
  If(cond: Value, result: List(ValType), then_branch: Expr, else_branch: Expr)
  /// Multi-way switch on an integer selector with a mandatory default.
  Switch(selector: Value, result: List(ValType), arms: List(SwitchArm), default: Expr)
  // non-returning control transfers -------------------------------------------
  Break(label: String, values: List(Value))
  Continue(label: String, values: List(Value))
  Return(values: List(Value))
  // effects -------------------------------------------------------------------
  Trap(reason: TrapReason)
  /// Metering hook (D9): charge `cost` fuel, then continue. Inserted by ir_lower (11).
  Charge(cost: Int, body: Expr)
}

pub type LoopParam {
  LoopParam(name: String, ty: ValType, init: Value)
}

pub type SwitchArm {
  SwitchArm(match: Int, body: Expr)
}

// ───────────────────────────── Operations ─────────────────────────────

/// Neutral, width-tagged numeric ops (D6 — NOT WASM opcode strings). The emitter maps
/// these to concrete rt_num function names (see 06/08). Signed vs unsigned is a
/// fundamental low-level distinction (cf. LLVM sdiv/udiv), not a WASM-ism.
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
  // floats (lock-now; Phase-1 covers a subset end-to-end — see 06)
  FAdd(FloatWidth)
  FSub(FloatWidth)
  FMul(FloatWidth)
  FDiv(FloatWidth)
  FMin(FloatWidth)
  FMax(FloatWidth)
}

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
}

/// Phase-2 term-layer ops; lock-now placeholder so the term frontends don't retrofit.
pub type TermOp {
  MakeTuple
  TupleGet(index: Int)
  MakeCons
  // … extend in Phase 2
}

pub type MemAccess {
  /// width in bytes, signedness for sub-word loads — Phase-2.
  MemAccess(bytes: Int, signed: Bool)
}

pub type TrapReason {
  IntDivByZero
  IntOverflow
  // div_s INT_MIN / -1
  Unreachable
  IndirectCallTypeMismatch
  MemoryOutOfBounds
  // … extend in Phase 2
}
```

### Open questions for the freeze owner to resolve (then document the choice in the file)

1. **Names vs SSA indices.** The strawman uses `String` names for locals/labels. That
   is readable in `.ir`; the alternative is integer indices. Recommendation: keep
   `String` names (clearer `.ir`, easier debugging); require uniqueness within a
   function. The backend will alpha-rename to Core Erlang's variable rules anyway
   (see 08), so IR names need only be unique, not Core-legal. **Params are named too**
   (`Function.params: List(Local)`, resolved post-review) — the WASM frontend (unit 10)
   conventionally names them `%p0 … %p{n-1}` so the `.ir` text and body references line
   up. Confirm `ir-grammar.md`'s func header prints these names.
2. **`If` condition truthiness.** WASM `if` pops an i32 (0 = false). Keep `cond: Value`
   as an i32 and let the emitter test `≠ 0`. A future term frontend boxes its condition
   to an i32 (or we add a `TermCond` later) — do *not* bake a term-boolean into the
   Phase-1 `If`.
3. **Trapping numeric ops' result shape.** `Num(IDivS …)` conceptually returns
   `Result(value, TrapReason)`. Decide whether that is modelled in the IR `Expr` type
   or handled entirely by the emitter+rt_num ABI. Recommendation: keep the IR `Expr`
   clean (a `Num` yields a value), and let `emit_core` + `rt_num`'s `Result`-returning
   signatures (below) handle the trap raise. Document this so `08` and `06` agree.
4. **`Block`/`Loop` result threading.** Confirm the ANF shape lets a block's result be
   bound: `Let(["x"], Block("b", [TI32], …), body)`. Walk the three acceptance programs
   (`add`, `sum_to`, `fib`) through the types by hand and confirm each lowers cleanly
   before freezing.

### Neutrality review checklist (D6 — sign off in `state.md` before freezing)

- [ ] No type/field/constructor name contains a WASM opcode string (`i32.add`, etc.).
- [ ] Control transfers reference **named labels**, never a numeric depth/index.
- [ ] No operand-stack or stack-typing concept appears in the IR.
- [ ] A hypothetical JS frontend could emit `IAdd(W32)`, `If`, `CallHost`, `Let`, etc.
      with **no** WASM concept present. (Sanity-write two or three nodes for a trivial
      JS snippet on paper.)
- [ ] `memory` is a *separate* `Option` from `uses_numerics` (a numeric-only module
      sets `memory: None`).

---

## The runtime binding ABI (second keystone) — `runtime/instance.gleam`

This file defines **how generated code reaches the runtime** (D3). Phase 1 uses
**link-time-fixed binding (B2)**: the emitter resolves each runtime op to a direct
`call 'twocore@runtime@<impl>':'<fn>'/<arity>(...)`, choosing `<impl>` from a build-time
`Binding`. No record is threaded through generated code (D3d). No data-driven `apply`
(D3a).

```gleam
//// src/twocore/runtime/instance.gleam
//// The runtime binding (a BUILD-TIME descriptor consumed by emit_core's chokepoint,
//// D3b). It carries the Erlang MODULE NAME implementing each runtime layer. It is NOT
//// embedded in generated code (D3d). See 00-overview.md D2/D3.

pub type Mode {
  Safe
  Unsafe
}

/// Which compiled runtime module implements each layer. Module names are the
/// Gleam→Erlang-mangled names (path `/` → `@`), e.g. "twocore@runtime@rt_num".
/// emit_core emits `call '<field>':'<fn>'(...)` against these. Phase-2 adds
/// memory/table/state module fields here.
pub type Binding {
  Binding(
    mode: Mode,
    num_module: String,
    trap_module: String,
    host_module: String,
    meter_module: String,
    stdlib_module: String,
  )
}

/// The Phase-1 Safe profile (deny-all host, bif numerics, fuel metering, own stdlib).
/// Unit 11 may move profile construction to runtime/profiles.gleam; this stub gives
/// emit_core a target. Fail-closed: the default IS the safe one (D4/D9).
pub fn safe_default() -> Binding {
  Binding(
    mode: Safe,
    num_module: "twocore@runtime@rt_num",
    trap_module: "twocore@runtime@rt_trap",
    host_module: "twocore@runtime@rt_host",
    meter_module: "twocore@runtime@rt_meter",
    stdlib_module: "twocore@runtime@rt_stdlib",
  )
}
```

**Document the calling convention in this file's module doc** so `08` and `09` agree
exactly. The Phase-1 convention is:

| IR construct | Emitted Core Erlang (schematic) |
|---|---|
| `Num(IAdd(W32), [a, b])` | `call '<num_module>':'i32_add'(A, B)` |
| `Num(IDivS(W32), [a, b])` | `call '<num_module>':'i32_div_s'(A, B)` → `{ok,X}`/`{error,Reason}`; emitter `case`s, raising on error |
| `Trap(IntDivByZero)` | `call '<trap_module>':'raise'('int_div_by_zero')` |
| `CallHost(cap, name, args)` | `call '<host_module>':'call_host'(Cap, Name, [Args…])` (deny-all raises) |
| `Charge(cost, body)` | `call '<meter_module>':'charge'(Cost)` then `body` |

> The mapping `NumOp → rt_num function name` is owned by `08` (the chokepoint) but
> **must match the frozen `rt_num` signatures below** — that is the whole point of
> freezing them here.

**The two fates of `CallHost` (resolved post-review).** `ir_lower` (unit 11) runs
*before* `emit_core` and decides what each `CallHost` becomes:

- a `CallHost` that resolves to an **`own` stdlib** function is rewritten by `ir_lower`
  into a direct runtime call — `emit_core` emits
  `call '<stdlib_module>':'<fn>'(Args…)`. (So a vetted stdlib call does **not** go
  through the deny-all host.)
- a `CallHost` to a **genuine host import** is left as-is — `emit_core` emits
  `call '<host_module>':'call_host'(Cap, Name, [Args…])`, which under the Safe profile's
  `deny_all` host raises (fail-closed).

**`rt_bif` is a *build-time* gate, not a runtime layer** (high-level §4 marks R-bif
phase "build"). It is consulted by `ir_lower` (unit 11) to enforce the allowlist when
resolving `CallHost`/BIF targets; it is **not** in the `Binding` record and **not**
called by generated code. So `rt_bif`'s gate shape is frozen with **unit 11**, not 08.
(That is why `Binding` above has `stdlib_module` but no `bif_module`.)

---

## `rt_num` signatures — `runtime/rt_num.gleam` (bodies = `todo`, then unit 06 owns)

Freeze the **function heads** so `08` can emit calls and `06` can fill bodies without
either inventing names. Per-width functions (not a width parameter) keep hot-loop calls
direct. **Integer values are the raw unsigned bit pattern in `[0, 2^width)`** (the one
documented convention — see `06`). Trapping ops return `Result(Int, TrapReason)`; the
caller raises (D3 / decision in open-question 3).

```gleam
//// src/twocore/runtime/rt_num.gleam
//// SIGNATURES frozen by unit 01; BODIES implemented by unit 06 (the `bif`, tier-P
//// reference impl). Numeric fidelity invariants live here and ONLY here (D2).

import twocore/ir.{type TrapReason}

// Non-trapping i32 ops (operands & result are unsigned bit patterns in [0, 2^32)):
pub fn i32_add(a: Int, b: Int) -> Int { todo }
pub fn i32_sub(a: Int, b: Int) -> Int { todo }
pub fn i32_mul(a: Int, b: Int) -> Int { todo }
pub fn i32_and(a: Int, b: Int) -> Int { todo }
pub fn i32_or(a: Int, b: Int) -> Int { todo }
pub fn i32_xor(a: Int, b: Int) -> Int { todo }
pub fn i32_shl(a: Int, b: Int) -> Int { todo }
pub fn i32_shr_s(a: Int, b: Int) -> Int { todo }
pub fn i32_shr_u(a: Int, b: Int) -> Int { todo }
pub fn i32_rotl(a: Int, b: Int) -> Int { todo }
pub fn i32_rotr(a: Int, b: Int) -> Int { todo }
pub fn i32_clz(a: Int) -> Int { todo }
pub fn i32_ctz(a: Int) -> Int { todo }
pub fn i32_popcnt(a: Int) -> Int { todo }
pub fn i32_eqz(a: Int) -> Int { todo }
pub fn i32_eq(a: Int, b: Int) -> Int { todo }
pub fn i32_ne(a: Int, b: Int) -> Int { todo }
pub fn i32_lt_s(a: Int, b: Int) -> Int { todo }
pub fn i32_lt_u(a: Int, b: Int) -> Int { todo }
// … gt_s/gt_u/le_s/le_u/ge_s/ge_u, and the full i64_* mirror …

// Trapping i32 ops — return Result; the EMITTER raises via rt_trap:
pub fn i32_div_s(a: Int, b: Int) -> Result(Int, TrapReason) { todo }
pub fn i32_div_u(a: Int, b: Int) -> Result(Int, TrapReason) { todo }
pub fn i32_rem_s(a: Int, b: Int) -> Result(Int, TrapReason) { todo }
pub fn i32_rem_u(a: Int, b: Int) -> Result(Int, TrapReason) { todo }
// … and the COMPLETE i64 mirror (i64_add … i64_ge_u, i64_div_s … i64_rem_u) …
```

**FREEZE THE COMPLETE PHASE-1 NAME LIST — not a subset.** Units 06 (bodies) and 08 (the
`NumOp → fn-name` table) both bind to these *names*; leaving floats/conversions as "…"
makes them race on spellings. The frozen set, by a fixed naming rule, is:

- **Integer (per width `w ∈ {i32, i64}`):** `w_add`, `w_sub`, `w_mul`, `w_and`, `w_or`,
  `w_xor`, `w_shl`, `w_shr_s`, `w_shr_u`, `w_rotl`, `w_rotr`, `w_clz`, `w_ctz`,
  `w_popcnt`, `w_eqz`, `w_eq`, `w_ne`, `w_lt_s`, `w_lt_u`, `w_gt_s`, `w_gt_u`, `w_le_s`,
  `w_le_u`, `w_ge_s`, `w_ge_u` (→ `Int`); and `w_div_s`, `w_div_u`, `w_rem_s`,
  `w_rem_u` (→ `Result(Int, TrapReason)`).
- **Conversions:** `i32_wrap_i64`, `i64_extend_i32_s`, `i64_extend_i32_u`,
  `i32_extend8_s`, `i32_extend16_s`, `i64_extend8_s`, `i64_extend16_s`,
  `i64_extend32_s`, `i32_reinterpret_f32`, `i64_reinterpret_f64`,
  `f32_reinterpret_i32`, `f64_reinterpret_i64`, and the saturating float→int
  `i32_trunc_sat_f32_s`, `i32_trunc_sat_f32_u`, `i32_trunc_sat_f64_s`,
  `i32_trunc_sat_f64_u`, `i64_trunc_sat_f32_s`, … `i64_trunc_sat_f64_u` (all → `Int`,
  the raw bit pattern; trunc_sat never traps).
- **Float (per width `w ∈ {f32, f64}`, operating on raw bit-pattern `Int`s):**
  `w_add`, `w_sub`, `w_mul`, `w_div`, `w_min`, `w_max` (→ `Int` bits).

> Spell out every head in the file with a `todo` body (use the rule above mechanically).
> Unit 01 fixes only the **names, arities, and Result-vs-bare-Int shape**; the spec-cited
> *semantics* (and the float = raw-bits representation, never a BEAM double) live in
> **unit 06**. Coordinate the final list with the 06 and 08 owners before announcing
> `«RTNUM-SIG-FROZEN»`.

---

## `pipeline.gleam` — the per-stage error composition (D4)

```gleam
//// src/twocore/pipeline.gleam — top-level driver glue. Per-stage errors (D4) compose
//// here; there is NO single shared StageError. Unit 11 completes the driver.

/// The union of every stage's own error type, assembled at the driver boundary.
/// Each variant wraps a stage-owned type (DecodeError lives in the decoder, etc.).
pub type PipelineError {
  DecodeFailed(detail: String)
  // 05 refines: wraps frontend/wasm/decode.DecodeError
  ValidateFailed(detail: String)
  // 10 refines: wraps frontend/wasm/validate.ValidateError
  LowerFailed(detail: String)
  EmitFailed(detail: String)
  BuildFailed(detail: String)
}
```

> Stages return their **own** error type; `11` maps each into a `PipelineError` variant
> at the seam. As each stage lands, the owner replaces the `detail: String` placeholder
> with their real type. Keep this loose until the stage types exist — that is the
> point of D4 (independent evolution).

---

## Verification (Definition of Done for unit 01)

- `gleam build` compiles all stubs with **no warnings** (`todo` bodies are fine).
- `gleam format --check src test` is clean.
- The neutrality checklist (above) is signed off in `state.md`.
- `ir-grammar.md` describes a textual form that can express **every** `Expr`/`Module`
  variant, and at least the hand-authored golden `.ir` files parse-by-eye against it
  (the actual parser is `02`).
- The three acceptance programs (`add`, `sum_to`, `fib`) have been written **by hand as
  IR values** in a scratch test and typecheck — proving the types can express the
  Phase-1 slice before anyone builds on them. (Keep these as the first golden `.ir`
  fixtures.)
- Milestones **«IR-FROZEN» / «ABI-FROZEN» / «RTNUM-SIG-FROZEN»** announced in
  `state.md`, with the "what this leaves" column filled.

## What this unit leaves for others

- `02` can build the printer/parser against `ir.gleam` + `ir-grammar.md`.
- `08` can build `emit_core` against `ir.gleam` + `instance.gleam` (the convention) +
  the frozen `rt_num` names.
- `06` can implement `rt_num` bodies against the frozen signatures.
- `10` (lower) and `11` (ir_lower) can target `ir.gleam`.
