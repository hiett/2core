# Unit 10 — WASM `full` validate (security boundary) & lower to IR

> **Two sub-units, splittable to two agents along one clean seam (the `TypedModule`
> type).** 10a = `validate` (Wave B, the security boundary; depends only on
> `«WASM-AST»`). 10b = `lower` (Wave B; depends on `TypedModule` + `«IR-FROZEN»`).
> Read [`00-overview.md`](00-overview.md) (D1–D10) and [`01-interface-freeze.md`](01-interface-freeze.md)
> (the IR) before touching this.

---

## Context

This is the back half of the WASM frontend (high-level §8.1: *decode → validate →
stack-elim → structure→IR*). Unit `05` hands you a decoded `wasm.Module` AST. Your job
is to (a) **prove it well-typed** so downstream stages can trust types, then (b) **lower
it into the shared IR** (`src/twocore/ir.gleam`). Lowering is the *easy structured→IR*
direction — WASM is already structured, so we side-step the relooper problem entirely
(high-level §8.1 last bullet). Your IR output is the input to the middle-end (`11`'s
`ir_lower`) and then `08`'s `emit_core`. See `00-overview.md` §4 for where this sits;
this doc does not repeat the file-ownership map.

## Goal

A measurable outcome in two halves:

- **10a:** `validate(wasm.Module) -> Result(TypedModule, ValidateError)` implements WASM
  **`full`** validation (abstract stack typing). Every module in the spec suite's
  `assert_invalid` set is **rejected** with a typed `ValidateError`; every valid module
  is accepted. This gates **independently of the IR** — it needs only the WASM AST.
- **10b:** `lower(TypedModule) -> Result(ir.Module, LowerError)` eliminates the operand
  stack into named SSA values and emits the shared IR, with structured control mapped
  onto the IR's **named-label** constructs (D6). The lowered IR **round-trips through
  `.ir`** (unit `02`) and, end-to-end at the capstone (`11`), compiles+runs to
  spec-correct results for the Phase-1 op set.

## Files owned

| File | Sub-unit | Note |
|---|---|---|
| `src/twocore/frontend/wasm/validate.gleam` | **10a** | The `full` validator + `ValidateError` + the `TypedModule` type (the 10a↔10b seam — **freeze it day 1**). Reads `ast.gleam` only; never mutates it. |
| `src/twocore/frontend/wasm/lower.gleam` | **10b** | stack-elim/SSA **and** structure→IR together (they share the SSA naming context — do **not** split them). `LowerError` lives here. |
| `test/twocore/frontend/wasm/validate_test.gleam` | **10a** | spec `assert_invalid` rejection + valid-accept suite. |
| `test/twocore/frontend/wasm/lower_test.gleam` | **10b** | lowering shape + `.ir` round-trip assertions. |

## Depends on

- **10a** depends **only** on `«WASM-AST»` — `frontend/wasm/ast.gleam` + its
  `DecodeError`, published day 1 by unit `05`. It does **not** need the IR. Stub
  against unit `05`'s published AST stub; if it is not landed yet, model the AST nodes
  you need from the WASM binary-format spec and re-sync when the real stub lands.
- **10b** depends on `«IR-FROZEN»` (unit `01`: `ir.gleam` + `ir-grammar.md`) **and** on
  `TypedModule` from 10a. Stub against the `01` IR strawman meanwhile.
- Round-trip verification of 10b's output uses unit `02`'s `.ir` printer/parser. End-to-
  end run uses `08`/`04` — but **10b's own DoD does not block on the backend** (see DoD).

## Scope — in / out for Phase 1

**In:**
- `full` validation strength only (untrusted input — **required**; high-level §8.1).
- `i32`/`i64` op set; `block`/`loop`/`if`/`br`/`br_if`/`br_table`/`return`; direct
  `call`; `local.get/set/tee`; `global.get/set` for the corpus; const ops.
- **Multi-value** block/loop/if (params + multiple results) — Phase-1 scope.
- Sign-extension ops and non-trapping float→int conversions (high-level §12 Phase-1).

**Out (Phase 1 — keep deferred):**
- `subset` / `assume_valid` strengths — Phase-2 / explicit-flag only. `assume_valid` is
  **unsafe on untrusted input** (D4/D9 fail-closed: never the default).
- `call_indirect` lowering — no Phase-1 corpus program uses it; **leave it
  unimplemented behind a clear `LowerError`**, never a panic.
- Memory/table/global lowering beyond what the corpus uses; WAT text (use `wat2wasm`
  fixtures). Per D9, the optimizer and breadth are Phase-2.

## Deliverables

### 10a — `validate`

```gleam
/// Proves `module` well-typed per WASM `full` validation and returns the typing
/// information lowering needs. `Ok(TypedModule)` ⇒ every function body type-checks,
/// every index is in bounds, every branch arity matches. `Error(ValidateError)` ⇒
/// the module is invalid (the security boundary REJECTS it — fail-closed, never panics).
pub fn validate(module: wasm.Module) -> Result(TypedModule, ValidateError)
```

`TypedModule` is a **separate** structure (do **not** add fields to `ast.gleam`). It
carries exactly what 10b needs so lowering never re-derives types. Strawman seam — flesh
out, then freeze for 10b:

```gleam
pub type TypedModule {
  TypedModule(
    module: wasm.Module,           // original AST, unmutated
    imported_func_count: Int,      // the funcidx offset (see pitfalls) — NOT baked away
    func_types: List(ir.FuncType), // type of every function, indexed by funcidx (imports ++ defined)
    funcs: List(TypedFunc),        // per defined-function typing lowering consumes
  )
}

pub type TypedFunc {
  TypedFunc(
    local_types: List(ir.ValType), // params ++ declared locals, FULLY EXPANDED, indexed 0..
    // the body annotated so each structured instr carries its RESOLVED blocktype
    // (expanded to FuncType: params -> results) and each instr its operand arity.
    body: TypedBody,
  )
}
```

`ValidateError` is **this stage's own type** (D4 — not a shared enum). Cover at least:
stack type mismatch, operand-stack underflow, unknown local/global/func/type/label
index, `br`/`br_table` label-arity mismatch, mismatched `if`/`else` result types,
`call` signature mismatch, unexpected end-of-body. Add variants as the spec rules
demand; each should carry enough position/detail to diagnose.

**Algorithm — the appendix validation algorithm** (transcribe faithfully from
<https://webassembly.github.io/spec/core/appendix/algorithm.html>; the typing rules are
<https://webassembly.github.io/spec/core/valid/>). Maintain a **value-type stack** and a
**control-frame stack**; the polymorphic-after-`unreachable` handling is the part most
implementations get wrong:

```
ctrl_frame = { opcode, start_types, end_types, height, unreachable: Bool }
vals  : stack(ValType | Unknown)
ctrls : stack(ctrl_frame)

pop_val():
  if vals.size == ctrls[0].height && ctrls[0].unreachable: return Unknown   // polymorphic
  error_if(vals.size == ctrls[0].height)                                    // underflow
  return vals.pop()
pop_val(expect): a = pop_val(); error_if(a != expect && a != Unknown && expect != Unknown); a

push_ctrl(opcode, in, out): ctrls.push({opcode, in, out, vals.size, False}); push_vals(in)
pop_ctrl(): f = ctrls[0]; pop_vals(f.end_types); error_if(vals.size != f.height); ctrls.pop(); f

label_types(f):  f.opcode == loop ? f.start_types : f.end_types      // ← LOOP uses INPUT types
unreachable():   vals.resize(ctrls[0].height); ctrls[0].unreachable = True
```

- `block`/`if` → `push_ctrl` then on `end` `pop_ctrl`; `loop` likewise but `label_types`
  is its **input** types (a branch to a loop targets its head, not its end).
- `br N` / `br_if N` / `br_table`: bounds-check the depth `N` against `ctrls`, then
  pop/match `label_types(ctrls[N])`. `br` and `br_table` arms end with `unreachable()`.
  All `br_table` targets **and** the default must share the same `label_types` arity.
- `call f`: look up `func_types[f]`, pop params, push results.
- `local.get/set/tee`, `global.get/set`: bounds-check the index against the (expanded)
  local / global type list.

### 10b — `lower`

```gleam
/// Lowers a validated module into the shared IR. The operand stack (whose shape is
/// statically known from validation) becomes named SSA bindings; structured control
/// becomes the IR's NAMED-label constructs (D6). Sets `uses_numerics: True`,
/// `memory: None`. `Error(LowerError)` only for constructs out of Phase-1 scope
/// (e.g. call_indirect) — fail-closed, never a panic.
pub fn lower(typed: TypedModule) -> Result(ir.Module, LowerError)
```

Three jobs, sharing one SSA naming context (why 10b is one file):

1. **Stack-elim / SSA.** Keep an abstract `stack: List(name)` (names, **no runtime
   stack**) and a `locals: Dict(index, name)` env. Each value-producing instr pops its
   arg *names*, emits `Let([fresh], <op>, …)`, and pushes `fresh`. `local.get i` pushes
   `locals[i]`; `local.set i` pops a name into `locals[i]`; `local.tee i` peeks. Const
   ops push a `ConstI32(bits)` / `ConstI64(bits)` operand (raw unsigned bits).
2. **Structure → IR (depth → named label — D6, critical).** WASM branches by **numeric
   label depth** (`br N` = exit/continue `N` frames out). **Resolve relative depths into
   the IR's named labels here, at the frontend boundary — never pass a depth into the
   IR.** Maintain a label stack while walking; `br N` consults frame `N`:
   - target frame is a **`loop`** → `ir.Continue(label, vals)` (re-enter the head);
   - target frame is a **`block`/`if`** → `ir.Break(label, vals)` (exit forward);
   - `return` → `ir.Return(vals)`.
   Map WASM `block`/`loop`/`if`/`switch(br_table)` → `ir.Block`/`Loop`/`If`/`Switch`.
3. **Ops & values.** Numeric instrs → `ir.Num(op, args)` with the **neutral,
   width-tagged** `NumOp` (`IAdd(W32)` — never the string `"i32.add"`, D6). Params/locals
   → named `Var`s; the function's `locals` list → `ir.Local`. Trapping ops (`div_s`
   etc.) stay a plain `Num` in the IR — the trap raise is `08`+`06`'s job (per `01`
   open-question 3), not yours.

`LowerError` (this stage's own type, D4): at minimum `Unsupported(detail)` (e.g.
`call_indirect`, any memory/table op outside corpus scope). Lowering is **total**: an
out-of-scope construct returns `Error`, it does not `panic`/`let assert`.

> **Walk the golden examples before writing code.** `add`, `sum_to`, and `fib` are
> hand-authored `.ir` in [`ir-grammar.md`](ir-grammar.md). Your lowering must produce
> *exactly that shape*: e.g. `sum_to`'s loop carries `%i`/`%acc` as `LoopParam`s and
> ends each iteration with `continue $go (%i1, %acc1)`; `add` is a single
> `return ( num i.add.32 (%p0, %p1) )`.

## Grounded facts you MUST honor

- **Index spaces (do not bake `funcidx == code-index`).** The funcidx space is
  **imported functions THEN defined functions**. Phase-1 has no imports, so
  `funcidx == defined index` *today* — but keep an **explicit `imported_func_count`
  offset**. A `call f` with `f < imported_func_count` is a host import (→ `CallHost` at
  the capability boundary in Phase 2); otherwise it is a defined function (→
  `CallDirect`). Baking the equality in breaks the `call_host`/imports boundary the
  moment Phase-2 adds imports.
- **Locals base.** Locals are **RLE-expanded** (the unit-`05` decoder already expands
  the run-length local groups). **Params occupy indices `0..k-1`** before the declared
  locals. Lowering must index from the right base — `local_types` is the concatenation
  `params ++ declared`, indexed from 0.
- **Mutated locals become loop-carried vars.** The IR is functional/SSA, so a local
  *written inside a loop body* cannot keep a stale pre-loop SSA name. Promote every
  local assigned within a loop to a `LoopParam` (init = its current name, rebound on
  `Continue`) — this is exactly why `sum_to`'s `%i`/`%acc` are loop params even though
  WASM models them as mutable locals, not operand-stack loop params.
- **Multi-value blocktypes (`s33` typeidx) are in scope.** A `block`/`loop`/`if`
  blocktype may be empty, a single valtype, or a **typeidx** giving `params -> results`.
  Block/loop/if can therefore take params and return **multiple** values: your SSA stack
  handling and the IR `result`/`LoopParam` lists must handle **arity > 1**.
- **`if` without `else`.** The IR `If` has **both** arms. When the WASM `if` has no
  `else`, **synthesize an empty else arm that forwards the right values** — i.e. yields
  the block's params straight through as its results (which is why a missing-else
  blocktype must have `params == results`).
- **IR is ANF + named labels.** Confirm your output against the `add`/`sum_to`/`fib`
  golden `.ir` (above). No operand-stack concept, no numeric depth, no WASM opcode
  string may appear in the IR (D6 neutrality).
- **Module flags.** Emit `Module(uses_numerics: True, memory: None, …)` — a Phase-1 WASM
  module turns numerics on and links no memory runtime (D5).

## Verification — Definition of Done (D8)

Tests assert **spec behavior, not whatever the code emits** (no change-detector tests).

**10a:**
- A representative `assert_invalid` subset from the spec suite (provided by unit `07`)
  is each rejected with a `ValidateError`. Assert against the **validation rules**
  (<https://webassembly.github.io/spec/core/valid/>) — e.g. type mismatch, out-of-range
  label/index, `br` arity mismatch, `if`/`else` result mismatch — not against the
  message text. Include the polymorphic-stack cases (`unreachable` followed by stack-
  polymorphic instructions) since they are the algorithm's hard part.
- Valid modules (incl. the `add`/`sum_to`/`fib` corpus, multi-value blocks, and an
  empty-`else` `if`) are accepted.
- **Fail-closed:** a hostile/truncated/edge module produces a typed `Error`, **never** a
  panic (no `let assert` on untrusted input — that is a sandbox hole, §5 conventions).
- This suite runs with **no IR dependency** — it gates 10a independently.

**10b:**
- Lower the corpus, then assert `parse(print(lowered)) == lowered` via unit `02`
  (D7 round-trip; float literals compared by **bit pattern**). This is 10b's **own
  DoD** — *valid IR that round-trips* — so the frontend is **not blocked on the
  backend**.
- Assert structural facts the spec/IR demand: `br N` targeting a `loop` lowered to
  `Continue` and targeting a `block`/`if` to `Break`; depths fully resolved to named
  labels (no depth survives into the IR); `uses_numerics: True`, `memory: None`; a
  mutated-in-loop local appears as a `LoopParam`.
- `call_indirect` (and any out-of-scope construct) returns `LowerError`, asserted — not
  a panic.
- **(Integration, owned by capstone `11`, not a 10b blocker):** lowered IR compiles +
  runs end-to-end to spec-correct results for the Phase-1 op set.

**Both:** every public function has a doc comment stating its contract (what / params &
ranges / `Result` semantics / failure & panic modes); `gleam format --check src test`
clean; `gleam build` with **no warnings**. When a bug is found, add the failing
spec-encoded test first, then fix.

## Concurrency

The clean seam is the **`TypedModule` type**:

- **10a (validate)** and **10b (lower)** go to two agents. 10a publishes
  `TypedModule` + `ValidateError` as a compiling stub **on day 1** (a mini-freeze, like
  `05` does for the AST) so 10b can target it immediately; 10a then fills the algorithm.
- **Freeze first:** `«WASM-AST»` (for 10a) and `«IR-FROZEN»` + `TypedModule` (for 10b).
- **Do NOT split 10b further.** Stack-elim and structure→IR share the SSA naming context
  (the `stack` + `locals` env threaded through the structured-control walk); separating
  them just creates a chatty internal interface for no gain.
- 10a *could* be sub-divided (instruction typing vs module-level/section validation),
  but they share the `vals`/`ctrls` machinery — only split if one agent is overloaded.

## What this leaves for others

- The **WASM frontend's output — a shared `ir.Module`** — ready for the middle-end
  (`11`'s `ir_lower`: capability/stdlib resolution + `charge` insertion) and then
  `08`'s `emit_core`. This is the frontend half of the Phase-1 vertical slice; the
  capstone (`11`) wires it to the backend for the differential acceptance run.
- An **independently-auditable security boundary** (`validate.gleam`) whose conformance
  is gated on the spec `assert_invalid` corpus without any backend dependency.
