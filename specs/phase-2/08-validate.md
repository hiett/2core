# Unit 08 — validate extension (typing the new ops; the security boundary)

> **One owner · Wave B · AST-only.** Gates on **`«WASM-AST2»`** (unit 07's type stub,
> published day 1) — *not* on completed decoding — and runs in **parallel** with all the
> IR/runtime work (it never imports `twocore/ir`). Read [`00-overview.md`](00-overview.md)
> (E1–E8) and [`01-interface-freeze.md`](01-interface-freeze.md) first; D1–D10 still hold.

---

## Context

`validate.gleam` is the **security boundary** (overview D4/D9, E3). Its input AST is
populated from UNTRUSTED bytes; everything downstream — lowering, emit_core, the runtime
— *trusts* that a module which validated is well-typed, so it can emit straight-line code
with no re-checks. Phase 1 shipped a faithful transcription of the spec's abstract
stack-typing algorithm (vals/ctrls stacks, polymorphic-after-`unreachable`, label types,
the else-less-`if` rule, per-function `max_locals` cap). It covers integers, the structured
control set, `call`, `select`, and the saturating truncations — but it **rejects every new
Phase-2 op** (`call_indirect` → `Unsupported`; `global.*` → `UnknownGlobal`; load/store/
`memory.*`/float-arith/the conversion block don't exist in the Phase-1 AST at all).

Phase 2 turns those on. This unit extends the *typing* so lowering can trust the new ops,
and — critically — **fail-closed-rejects** ill-typed modules with a spec-cited error. The
validator gates **independently of the IR**: a type-unsafe module must be rejected here even
if the backend would have coincidentally produced something.

## Goal

Extend the abstract-stack validator to every Phase-2 op so that (a) every well-typed module
is accepted and carries the typing facts lowering needs, and (b) every ill-typed module is
rejected with the `ValidateError` the spec rule demands — **without** touching the Phase-1
polymorphic-stack / label algorithm.

## Files owned

| File | Action |
|---|---|
| `src/twocore/frontend/wasm/validate.gleam` | **EXTEND** (single-owner; AST-only — the security boundary). |
| `test/twocore/frontend/wasm/validate_test.gleam` | **EXTEND** — spec-cited acceptance + rejection tests for the new ops. |

No other file. This unit imports `twocore/frontend/wasm/ast` **only** (no `twocore/ir`).

## Depends on

- **`«WASM-AST2»`** (unit 07, day 1) — the extended `ast.gleam`: the new instruction
  constructors (load/store matrix, `memory.size/grow`, the `0xA7–0xBF` conversions, float
  arith/unary/copysign/compare, `select`), each load/store carrying its **memarg**
  (`align`, `offset`), plus the new `ast.Module` fields (`memory`, `globals`, `tables`,
  `elements`, `data`, `start`) and their decl types (`Global(ty, mutable, init)`,
  `TableType(min, max)` — funcref implicit, `MemType`, `ElementSegment`, `DataSegment`).
- **Stub against it meanwhile:** unit 07 owns the *exact* spelling. Write the typing tables
  keyed by the spec **mnemonic + natural byte width** (below) and bind them to whatever
  constructor names 07 ships; if 07's load/store carrier differs (per-opcode ctors vs. one
  `Load(kind, memarg)`), the table maps unchanged — only the `case` patterns differ. Confirm
  field names with 07 the moment `«WASM-AST2»` lands.

## Scope — in / out for Phase 2

**In:** typing for load/store (full width matrix), `memory.size`/`memory.grow`,
`global.get`/`global.set` (incl. the **mutability** check), `call_indirect` (typeidx +
table-exists), the float arith/unary/copysign/compare ops, the full `0xA7–0xBF` int↔float
conversion block (operand/result widths), `select` (untyped `t t i32 -> t`); **memarg
alignment** validation (`2^align ≤ natural byte-width`); **const-expr** validation for
global initializers and element/data segment offsets (MVP grammar: `t.const` only); a
`start`-function type check; and **carrying the global value-types** lowering needs.

**Out (defer — state it, don't drop it):**
- **Reference-type validation** (E2/E8): `externref`/`funcref` value-typed `global`s,
  `table.get/set/copy/fill`, **typed `select_t`** (0x1C). `select_t` stays
  `Unsupported`. → Phase 3.
- **Non-function imports** (E7): imported memory/table/global + the `spectest` module → the
  const-expr `global.get`-of-imported-immutable case has no referent in Phase 2 (reject).
  → Phase 3.
- **Bulk-memory / multi-memory / SIMD / memory64** — the decoder (07) rejects them; validate
  assumes **at most one memory and one table** (index 0).
- All runtime trap behavior (OOB, indirect-call type mismatch, trapping-trunc NaN/overflow)
  is **dynamic**, *not* validation — validate only checks static operand/result widths.

## Deliverables

### 1. New `ValidateError` variants (additive; keep the Phase-1 ones)

```gleam
pub type ValidateError {
  // … existing: TypeMismatch, Underflow, UnknownLocal, UnknownGlobal, UnknownFunc,
  //              UnknownType, UnknownLabel, BranchArityMismatch, IfElseMismatch,
  //              UnexpectedEnd, TooManyLocals, Unsupported …
  UnknownMemory(index: Int)      // a memory op but the module declares no memory
  UnknownTable(index: Int)       // call_indirect / elem but no table declared
  ImmutableGlobal(index: Int)    // global.set on a const (immutable) global
  BadAlignment                   // memarg: 2^align > natural access byte-width
  NonConstantExpr                // an init/offset expr uses a non-const instruction
}
```

### 2. `TypedModule` carries the global value-types lowering needs

```gleam
pub type TypedModule {
  TypedModule(
    module: Module,
    imported_func_count: Int,
    func_types: List(FuncType),
    func_locals: List(List(ValType)),
    global_types: List(ValType),   // NEW: value type of each global by index
  )
}
```

Load **result types are encoded in the opcode** (the AST constructor distinguishes
`i32.load8_s` from `i64.load8_s`), so lowering reads them off the instruction — *don't*
add a per-instruction annotation map. `call_indirect`/`global.get` result types are
recoverable from `module.types`/`global_types`, which lowering already reads. The one
fact not trivially re-derivable that validate must compute anyway (for the mutability
check) is `global_types`; carry exactly that.

### 3. A validation context threaded into `validate_instr`

The new ops need module-level facts the Phase-1 signature lacked. Replace the loose
`types, func_types, locals` params with one record (keeps the algorithm otherwise intact):

```gleam
type Ctx {
  Ctx(
    types: List(FuncType),
    func_types: List(FuncType),       // per-funcidx signatures (imports ++ defined)
    globals: List(#(ValType, Bool)),  // (type, mutable?) by global index
    has_memory: Bool,                 // module declares memory 0
    has_table: Bool,                  // module declares table 0 (funcref)
    locals: List(ValType),
  )
}
```

`memory.size/grow` and every load/store check `ctx.has_memory` (else `UnknownMemory(0)`);
`call_indirect` checks `ctx.has_table` (else `UnknownTable(0)`).

### 4. Typing rules (the spec signatures — see Grounded facts for the verbatim tables)

- **Loads** → in `validate_instr` (they need `ctx` for memory + alignment): pop `i32`
  address, push the load's result type. **Stores**: pop `value`, pop `i32` address, push
  nothing. Validate the **memarg alignment** for both.
- **`memory.size`** `() -> i32`; **`memory.grow`** `(i32) -> i32`.
- **`global.get i`** → push `globals[i].0` (range-check `i` → `UnknownGlobal`).
  **`global.set i`** → range-check, **require `globals[i].1 == True` (mutable)** else
  `ImmutableGlobal(i)`, then pop `globals[i].0`.
- **`call_indirect y`** → `UnknownType(y)` if `y` ∉ `types`; `UnknownTable(0)` if no table;
  pop `i32` (the table index, top of stack) then pop `types[y].params`, push
  `types[y].results`. The **dynamic** type check is runtime, not here.
- **Float arith/unary/copysign/compare + the `0xA7–0xBF` conversions + `select`** → pure
  operand/result signatures: extend `numeric_sig` (no `ctx` needed). `select` keeps the
  Phase-1 `t t i32 -> t` impl (resolve `Unknown`, require the two values agree).

### 5. Const-expr validation

```gleam
/// A constant expression (global init / element & data offset) is valid iff it reduces to
/// a single `t.const` of `expected`. global.get is only valid against an immutable IMPORTED
/// global (none exist in Phase 2) → reject. Any other instruction (e.g. extended-const
/// i32.add) → NonConstantExpr. A const of the wrong type → TypeMismatch.
fn validate_const_expr(
  init: List(Instr), expected: ValType, ctx: Ctx,
) -> Result(Nil, ValidateError)
```

Apply it to: each `global` init (`expected` = the global's declared type), each active
**element** segment offset (`expected` = `i32`), each active **data** segment offset
(`expected` = `i32`). For elements: every funcidx must be in the function index space.
For a `start` function: the funcidx is in range **and** its type is `[] -> []` (spec).

## Grounded facts you MUST honor

Sources verified against the WebAssembly core spec (cited inline):
`valid/instructions` <https://webassembly.github.io/spec/core/valid/instructions.html>,
`valid/modules` <https://webassembly.github.io/spec/core/valid/modules.html>,
`appendix/algorithm` <https://webassembly.github.io/spec/core/appendix/algorithm.html>.

**Load/store width matrix** (operand types, result type, **natural byte-width** N/8 for the
alignment check). Address operand is `i32`; stores pop the value then the address.

| op | operands → result | nat. bytes | max align exp |
|---|---|---|---|
| `i32.load` `f32.load` | `[i32] → [i32]`/`[f32]` | 4 | 2 |
| `i64.load` `f64.load` | `[i32] → [i64]`/`[f64]` | 8 | 3 |
| `i32.load8_s/u` | `[i32] → [i32]` | 1 | 0 |
| `i32.load16_s/u` | `[i32] → [i32]` | 2 | 1 |
| `i64.load8_s/u` | `[i32] → [i64]` | 1 | 0 |
| `i64.load16_s/u` | `[i32] → [i64]` | 2 | 1 |
| `i64.load32_s/u` | `[i32] → [i64]` | 4 | 2 |
| `i32.store` `f32.store` | `[i32, i32]`/`[i32, f32] → []` | 4 | 2 |
| `i64.store` `f64.store` | `[i32, i64]`/`[i32, f64] → []` | 8 | 3 |
| `i32.store8` | `[i32, i32] → []` | 1 | 0 |
| `i32.store16` | `[i32, i32] → []` | 2 | 1 |
| `i64.store8` | `[i32, i64] → []` | 1 | 0 |
| `i64.store16` | `[i32, i64] → []` | 2 | 1 |
| `i64.store32` | `[i32, i64] → []` | 4 | 2 |

- **Alignment rule (`valid/instructions`, the memarg rule):** *"The alignment `2^align` must
  not be larger than `N/8`."* So reject with `BadAlignment` iff `2^align > nat_bytes`,
  i.e. iff `align > max_align_exp`. Alignment is a **non-semantic hint** — never reject for
  *under*-alignment; unaligned accesses are legal. After the check, validate discards
  `align` (lowering ignores it). Routed from **`align.wast`** `assert_invalid`.
- Stores: the load `signed` distinction is irrelevant for stores (a store writes the low N
  bits); typing ignores it. Document it.

**Float ops** (extend `numeric_sig`; per width `w ∈ {f32, f64}`):

| ops | signature |
|---|---|
| `w.add w.sub w.mul w.div w.min w.max w.copysign` | `[w, w] → [w]` |
| `w.abs w.neg w.ceil w.floor w.trunc w.nearest w.sqrt` | `[w] → [w]` |
| `w.eq w.ne w.lt w.gt w.le w.ge` | `[w, w] → [i32]` |

**The int↔float conversion block `0xA7–0xBF`** (`valid/instructions` numeric conversions —
**typing is width-only; trapping vs. saturating is a runtime concern, identical signatures**):

| op | sig | | op | sig |
|---|---|---|---|---|
| `i32.wrap_i64` (0xA7) | `[i64]→[i32]` | | `f32.convert_i32_s/u` (0xB2/B3) | `[i32]→[f32]` |
| `i32.trunc_f32_s/u` (0xA8/A9) | `[f32]→[i32]` | | `f32.convert_i64_s/u` (0xB4/B5) | `[i64]→[f32]` |
| `i32.trunc_f64_s/u` (0xAA/AB) | `[f64]→[i32]` | | `f32.demote_f64` (0xB6) | `[f64]→[f32]` |
| `i64.extend_i32_s/u` (0xAC/AD) | `[i32]→[i64]` | | `f64.convert_i32_s/u` (0xB7/B8) | `[i32]→[f64]` |
| `i64.trunc_f32_s/u` (0xAE/AF) | `[f32]→[i64]` | | `f64.convert_i64_s/u` (0xB9/BA) | `[i64]→[f64]` |
| `i64.trunc_f64_s/u` (0xB0/B1) | `[f64]→[i64]` | | `f64.promote_f32` (0xBB) | `[f32]→[f64]` |
| `i32.reinterpret_f32` (0xBC) | `[f32]→[i32]` | | `i64.reinterpret_f64` (0xBD) | `[f64]→[i64]` |
| `f32.reinterpret_i32` (0xBE) | `[i32]→[f32]` | | `f64.reinterpret_i64` (0xBF) | `[i64]→[f64]` |

- The trapping `trunc_f*_s/u` have the **same** signatures as the saturating
  `trunc_sat_*` already in `numeric_sig`; validation cannot and must not distinguish them.

**Globals & mutability** (`valid/instructions`): `global.get` is valid on any global;
`global.set` is valid **only if the global is `var` (mutable)** — setting a `const`
(immutable) global is a *validation* error → `ImmutableGlobal`. Routed from **`global.wast`**'s
40 `assert_invalid`. **Pitfall:** the mutability bit lives on the `global` decl
(`mut`: `0x00`=const, `0x01`=var), not the value type — thread it via `ctx.globals`.

**`call_indirect` validation** (`valid/instructions`): only the **static** `typeidx y`
must be in range and the table at index 0 must exist and be funcref. The **three runtime
traps** (`undefined element` / `uninitialized element` / `indirect call type mismatch`) are
**dynamic** — *do not* check them here. Binary immediate order is `0x11 y:typeidx x:tableidx`
(decoder's concern). Routed from **`call_indirect.wast`**'s 24 `assert_invalid`.

**Constant expressions** (`valid/instructions`, extended-const proposal
<https://github.com/WebAssembly/extended-const>): MVP permits **only** `t.const c` and
`global.get x` where `x` is an **immutable imported** global. Phase 2 has no imports → a
const-expr `global.get` has no valid referent → **reject** (`NonConstantExpr`).
**`global.wast` `$z3`/`$z5`** use `i32.add`/`i32.sub`/`i32.mul` and a `global.get` in an
init expr (extended-const) — 2core's MVP validator **must reject them (correct)**; those are
*valid* modules under extended-const, so the **conformance runner skips those asserts**
(honest skip — rejecting is the spec-correct MVP behavior, not a conformance failure).

**Keep intact (do not refactor away):** the polymorphic-stack model (`Known`/`Unknown`,
`pop_val` at frame base), `push_ctrl`/`pop_ctrl`, `label_types` (loop = input types),
`mark_unreachable`, the else-less-`if` `params==results` rule, and `max_locals`. `numeric_sig`
must stay **total** (its `_ -> #([], [])` fallthrough): every new leaf gets an explicit arm.

## Verification — Definition of Done (D8)

Tests assert the **spec rule**, not the implementation (no change-detector tests). Cite the
spec section / `.wast` file each test encodes. Fixtures: valid `.wasm` via `wat2wasm`;
invalid-but-decodable via `wat2wasm --no-check` (decode succeeds; only typing fails).

**Acceptance (must be `Ok`):**
- `i32.store` then `i32.load` round-trip module; a `load8_s`/`load16_u` module; a module
  with `f32.sqrt`/`f64.add`/`f32.eq`; a mutable-global `global.get`/`global.set` module; a
  `call_indirect` module with a declared funcref table and in-range typeidx; an
  `i32.wrap_i64` / `f64.convert_i32_s` / `i32.reinterpret_f32` module; a `select` of two
  i32s. Each must carry correct `global_types`.

**Rejection (must be the cited `Error`):**
- `BadAlignment` — `i32.load align=3` (2^3=8 > 4) and `i32.load8_s align=1` (2 > 1)
  (`align.wast` "alignment must not be larger than natural").
- `ImmutableGlobal` — `global.set` on a `const` global (`global.wast`; `valid/instructions`
  global.set rule).
- `NonConstantExpr` — a global init of `i32.const 0 i32.const 1 i32.add` (extended-const),
  and a global init using `global.get` (`global.wast` `$z3`/`$z5`; extended-const proposal).
- `TypeMismatch` — `i64.store` fed an `f32` value; `i32.load` with an `f64` address; a
  `select` of an i32 and an i64; a global init `f32.const` for an `i64` global.
- `UnknownType` — `call_indirect` with a typeidx past the type section (`call_indirect.wast`).
- `UnknownTable(0)` — `call_indirect` in a module with no table; `UnknownMemory(0)` — a
  load/`memory.size` in a module with no memory (`valid/instructions` "unknown memory/table").
- `UnknownGlobal` — `global.set`/`global.get` index out of range.
- start-function type ≠ `[] -> []` rejected (`valid/modules` start rule).

**Properties:** the module imports `twocore/frontend/wasm/ast` only — grep the source to
prove **no `twocore/ir` import** (gates independently of the backend). Total: never panics /
`let assert`s / diverges on any decodable AST. `gleam format --check src test` clean;
`gleam build` **zero warnings**; `gleam test` stays green (≥313).

**Prove the boundary end-to-end:** the conformance harness routes `assert_invalid` →
`check_frontend` (decode + validate) — confirmed in `test/twocore/conformance/driver.gleam`.
So the new negative corpora from **`memory_trap`/`address`/`align`/`global`/`call_indirect`/
the float files** flow here automatically; validate's rejection is what makes each
`assert_invalid` pass. Unit 11 wires the allowlist; your job is that the rejections are
spec-correct so those assertions go green (not silently skipped).

## Concurrency

Single owner, AST-only — must freeze `«WASM-AST2»` (07) first; nothing else blocks it. If
split among sub-agents: **(a)** the pure-signature leaves — float arith/unary/copysign/
compare + the `0xA7–0xBF` block + the load/store result types — in `numeric_sig` plus the
alignment helper; **(b)** the `ctx`-bearing ops — load/store memory-presence, `memory.*`,
`global.*` (+ mutability), `call_indirect`, and `Ctx` threading; **(c)** const-expr
validation + element/data/start checks + `global_types`. (a) and (b)/(c) share only the
`Ctx`/`ValidateError`/`TypedModule` shapes — freeze those three first, then parallelize.

## What this leaves for others

- **Unit 09 (lower)** consumes the extended `TypedModule` — reads `global_types`, trusts all
  types are sound, and never re-validates. (`select` lowers to `If`; the load result type is
  read off the opcode.)
- **Unit 10 (emit_core)** trusts the boundary: it emits the stateful-op calls with no type
  re-checks; the only runtime guards are the dynamic traps (OOB, indirect-call type mismatch).
- **Unit 11 (capstone)** adds the Phase-2 `.wast` allowlist; the `assert_invalid` from
  memory/global/call_indirect/align/float files land on this validator. Document the
  **skipped** `assert_invalid` it does *not* yet cover: reference-type validation
  (externref/funcref globals/tables, `select_t`) and non-function imports — Phase 3.
